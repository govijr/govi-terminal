"use client";

import { useSyncExternalStore } from "react";

const STORAGE_KEY = "govi-theme";

type Theme = "light" | "dark";

// The theme lives on <html data-theme>, set before hydration by the inline
// script in the layout. Reading it as an external store keeps the button in
// sync without a state update inside an effect.
function subscribe(onChange: () => void) {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  media.addEventListener("change", onChange);
  return () => {
    observer.disconnect();
    media.removeEventListener("change", onChange);
  };
}

function currentTheme(): Theme {
  const attr = document.documentElement.dataset.theme;
  const dark = attr ? attr === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
  return dark ? "dark" : "light";
}

export function ThemeToggle() {
  const theme = useSyncExternalStore(subscribe, currentTheme, (): Theme => "light");

  function toggle() {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {}
  }

  return (
    <button type="button" className="cursor-pointer text-muted transition-colors hover:text-ink" onClick={toggle} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} mode`}>
      {theme === "dark" ? "light mode" : "dark mode"}
    </button>
  );
}
