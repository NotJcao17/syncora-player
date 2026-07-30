tailwind.config = {
    darkMode: "class",
    theme: {
        extend: {
            colors: {
                background: "#181C27",
                surface: "#1E2633",
                "surface-hover": "#252E3D",
                "surface-active": "#2C3647",
                primary: "#FFFFFF",
                secondary: "#A0ABBA",
                muted: "#7F8C9D",
                accent: "#FFFFFF",
                "accent-glow": "rgba(255, 255, 255, 0.15)",
                "accent-glow-high": "rgba(255, 255, 255, 0.4)",
                error: "#ffb4ab",
                transparent: "transparent",
            },
            fontFamily: {
                sans: ["'Plus Jakarta Sans'", "sans-serif"],
            },
            fontSize: {
                "xs": ["12px", { lineHeight: "16px", letterSpacing: "0.05em", fontWeight: "600" }],
                "sm": ["14px", { lineHeight: "20px", fontWeight: "400" }],
                "base": ["16px", { lineHeight: "24px", fontWeight: "500" }],
                "lg": ["20px", { lineHeight: "28px", fontWeight: "600" }],
                "xl": ["24px", { lineHeight: "32px", letterSpacing: "-0.01em", fontWeight: "700" }],
                "2xl": ["28px", { lineHeight: "36px", fontWeight: "700" }],
                "3xl": ["32px", { lineHeight: "40px", letterSpacing: "-0.02em", fontWeight: "700" }],
            },
            spacing: {
                "xs": "4px",
                "sm": "8px",
                "md": "16px",
                "lg": "24px",
                "xl": "32px",
                "2xl": "48px",
            },
            borderRadius: {
                "sm": "4px",
                DEFAULT: "8px",
                "md": "12px",
                "lg": "16px",
                "xl": "24px",
                "full": "9999px",
            },
            boxShadow: {
                "glow": "0 0 20px rgba(255, 255, 255, 0.15)",
                "glow-high": "0 0 40px rgba(255, 255, 255, 0.3)",
                "surface": "0 8px 30px rgba(0, 0, 0, 0.12)",
                "surface-up": "0 -8px 30px rgba(0, 0, 0, 0.12)",
            }
        }
    }
};
