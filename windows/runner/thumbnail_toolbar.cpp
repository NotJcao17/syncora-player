#include "thumbnail_toolbar.h"

#include <flutter/standard_method_codec.h>
#include <commctrl.h>

#include <algorithm>
#include <string>

namespace {

constexpr int kIconSize = 20;

// Indices dentro de la image list. Play/pausa y corazon vacio/lleno son
// imagenes distintas porque `ThumbBarUpdateButtons` solo puede cambiar el
// indice de la imagen, no redibujarla.
constexpr int kImgPrevious = 0;
constexpr int kImgPlay = 1;
constexpr int kImgPause = 2;
constexpr int kImgNext = 3;
constexpr int kImgHeart = 4;
constexpr int kImgHeartFilled = 5;

constexpr UINT kBtnPrevious = 1;
constexpr UINT kBtnPlayPause = 2;
constexpr UINT kBtnNext = 3;
constexpr UINT kBtnLike = 4;

// Glifos de "Segoe MDL2 Assets", la fuente de iconos que Windows ya trae: usarla
// evita agregar assets .ico al repo y da el mismo trazo que el resto del shell.
constexpr wchar_t kGlyphPrevious = 0xE892;
constexpr wchar_t kGlyphPlay = 0xE768;
constexpr wchar_t kGlyphPause = 0xE769;
constexpr wchar_t kGlyphNext = 0xE893;
constexpr wchar_t kGlyphHeart = 0xEB51;
constexpr wchar_t kGlyphHeartFilled = 0xEB52;

// Dibuja un glifo blanco sobre fondo negro y deriva el canal alfa del brillo
// resultante. GDI no escribe alfa al pintar texto, asi que sin este paso el
// icono saldria como un cuadro negro opaco.
HICON CreateGlyphIcon(wchar_t glyph) {
  HDC screen_dc = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (!dc) {
    return nullptr;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = kIconSize;
  bmi.bmiHeader.biHeight = -kIconSize;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP color = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!color || !bits) {
    DeleteDC(dc);
    return nullptr;
  }
  memset(bits, 0, kIconSize * kIconSize * 4);

  HFONT font = CreateFontW(kIconSize, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_DONTCARE, L"Segoe MDL2 Assets");

  HGDIOBJ old_bitmap = SelectObject(dc, color);
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));

  RECT rect = {0, 0, kIconSize, kIconSize};
  std::wstring text(1, glyph);
  DrawTextW(dc, text.c_str(), 1, &rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);

  SelectObject(dc, old_font);
  SelectObject(dc, old_bitmap);
  DeleteObject(font);

  auto* pixels = static_cast<uint8_t*>(bits);
  for (int i = 0; i < kIconSize * kIconSize; ++i) {
    uint8_t* p = pixels + i * 4;
    uint8_t alpha = (std::max)({p[0], p[1], p[2]});
    p[0] = p[1] = p[2] = 255;
    p[3] = alpha;
  }

  HBITMAP mask = CreateBitmap(kIconSize, kIconSize, 1, 1, nullptr);
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmColor = color;
  info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&info);

  DeleteObject(mask);
  DeleteObject(color);
  DeleteDC(dc);
  return icon;
}

void AppendGlyph(HIMAGELIST list, wchar_t glyph) {
  HICON icon = CreateGlyphIcon(glyph);
  if (icon) {
    ImageList_AddIcon(list, icon);
    DestroyIcon(icon);
  }
}

}  // namespace

ThumbnailToolbar::ThumbnailToolbar() = default;

ThumbnailToolbar::~ThumbnailToolbar() {
  if (taskbar_) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  if (image_list_) {
    ImageList_Destroy(image_list_);
    image_list_ = nullptr;
  }
}

void ThumbnailToolbar::Initialize(HWND window,
                                  flutter::BinaryMessenger* messenger) {
  window_ = window;
  taskbar_button_created_ = RegisterWindowMessageW(L"TaskbarButtonCreated");

  channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, "syncora/thumbbar",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "update") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args) {
          auto playing = args->find(flutter::EncodableValue("isPlaying"));
          if (playing != args->end()) {
            if (const auto* v = std::get_if<bool>(&playing->second)) {
              is_playing_ = *v;
            }
          }
          auto liked = args->find(flutter::EncodableValue("isLiked"));
          if (liked != args->end()) {
            if (const auto* v = std::get_if<bool>(&liked->second)) {
              is_liked_ = *v;
            }
          }
        }
        UpdateButtons();
        result->Success();
      });
}

bool ThumbnailToolbar::HandleMessage(UINT message, WPARAM wparam) {
  if (taskbar_button_created_ != 0 && message == taskbar_button_created_) {
    AddButtons();
    return false;  // No consumir: otros componentes pueden querer verlo.
  }

  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    switch (LOWORD(wparam)) {
      case kBtnPrevious:
        SendAction("previous");
        return true;
      case kBtnPlayPause:
        SendAction("playPause");
        return true;
      case kBtnNext:
        SendAction("next");
        return true;
      case kBtnLike:
        SendAction("like");
        return true;
      default:
        break;
    }
  }
  return false;
}

void ThumbnailToolbar::AddButtons() {
  if (buttons_added_ || !window_) {
    return;
  }

  if (!taskbar_) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      return;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_->Release();
      taskbar_ = nullptr;
      return;
    }
  }

  if (!image_list_) {
    image_list_ = ImageList_Create(kIconSize, kIconSize, ILC_COLOR32, 6, 0);
    if (!image_list_) {
      return;
    }
    AppendGlyph(image_list_, kGlyphPrevious);
    AppendGlyph(image_list_, kGlyphPlay);
    AppendGlyph(image_list_, kGlyphPause);
    AppendGlyph(image_list_, kGlyphNext);
    AppendGlyph(image_list_, kGlyphHeart);
    AppendGlyph(image_list_, kGlyphHeartFilled);
  }

  if (FAILED(taskbar_->ThumbBarSetImageList(window_, image_list_))) {
    return;
  }

  THUMBBUTTON buttons[4] = {};

  buttons[0].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[0].iId = kBtnPrevious;
  buttons[0].iBitmap = kImgPrevious;
  buttons[0].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[0].szTip, L"Anterior");

  buttons[1].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[1].iId = kBtnPlayPause;
  buttons[1].iBitmap = is_playing_ ? kImgPause : kImgPlay;
  buttons[1].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[1].szTip, is_playing_ ? L"Pausar" : L"Reproducir");

  buttons[2].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[2].iId = kBtnNext;
  buttons[2].iBitmap = kImgNext;
  buttons[2].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[2].szTip, L"Siguiente");

  buttons[3].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[3].iId = kBtnLike;
  buttons[3].iBitmap = is_liked_ ? kImgHeartFilled : kImgHeart;
  buttons[3].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[3].szTip, L"Me gusta");

  if (SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 4, buttons))) {
    buttons_added_ = true;
  }
}

void ThumbnailToolbar::UpdateButtons() {
  if (!buttons_added_ || !taskbar_ || !window_) {
    return;
  }

  THUMBBUTTON buttons[2] = {};

  buttons[0].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[0].iId = kBtnPlayPause;
  buttons[0].iBitmap = is_playing_ ? kImgPause : kImgPlay;
  buttons[0].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[0].szTip, is_playing_ ? L"Pausar" : L"Reproducir");

  buttons[1].dwMask = static_cast<THUMBBUTTONMASK>(THB_BITMAP | THB_TOOLTIP | THB_FLAGS);
  buttons[1].iId = kBtnLike;
  buttons[1].iBitmap = is_liked_ ? kImgHeartFilled : kImgHeart;
  buttons[1].dwFlags = THBF_ENABLED;
  wcscpy_s(buttons[1].szTip, is_liked_ ? L"Quitar de Me gusta" : L"Me gusta");

  taskbar_->ThumbBarUpdateButtons(window_, 2, buttons);
}

void ThumbnailToolbar::SendAction(const char* action) {
  if (!channel_) {
    return;
  }
  channel_->InvokeMethod(
      "action", std::make_unique<flutter::EncodableValue>(std::string(action)));
}
