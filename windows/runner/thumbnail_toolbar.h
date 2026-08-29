#ifndef RUNNER_THUMBNAIL_TOOLBAR_H_
#define RUNNER_THUMBNAIL_TOOLBAR_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>

#include <memory>

// Botones de la vista previa de la barra de tareas (los que aparecen al pasar
// el mouse sobre el icono de la app).
//
// Esto NO es SMTC: `smtc_windows` implementa System Media Transport Controls,
// que alimenta el overlay de las teclas multimedia y el panel de volumen, pero
// no tiene nada que ver con la barra de tareas y no expone esta API. El hover
// del icono se dibuja con `ITaskbarList3::ThumbBarAddButtons`, que solo existe
// en Win32/COM, de ahi que viva aca en el runner y no en un paquete de Dart.
class ThumbnailToolbar {
 public:
  ThumbnailToolbar();
  ~ThumbnailToolbar();

  // Registra el canal de metodos y guarda el HWND propietario de los botones.
  void Initialize(HWND window, flutter::BinaryMessenger* messenger);

  // Devuelve true si el mensaje fue consumido. Debe llamarse desde el
  // `MessageHandler` de la ventana.
  bool HandleMessage(UINT message, WPARAM wparam);

 private:
  // Los botones solo se pueden agregar despues de que el shell anuncia que el
  // boton de la barra de tareas existe (`TaskbarButtonCreated`); hacerlo antes
  // falla en silencio.
  void AddButtons();
  void UpdateButtons();
  void SendAction(const char* action);

  HWND window_ = nullptr;
  UINT taskbar_button_created_ = 0;
  ITaskbarList3* taskbar_ = nullptr;
  HIMAGELIST image_list_ = nullptr;
  bool buttons_added_ = false;
  bool is_playing_ = false;
  bool is_liked_ = false;

  std::unique_ptr<flutter::MethodChannel<>> channel_;
};

#endif  // RUNNER_THUMBNAIL_TOOLBAR_H_
