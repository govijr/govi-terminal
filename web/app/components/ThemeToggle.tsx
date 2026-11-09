"use client";

import { useEffect, useState } from "react";

const STORAGE_KEY = "govi-theme";

export function ThemeToggle() {
  const [theme, setTheme] = useState<"light" | "dark">("light");

  useEffect(() => {
    const attr = document.documentElement.dataset.theme;
    const dark = attr ? attr === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
    setTheme(dark ? "dark" : "light");
  }, []);

  function toggle() {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {}
    setTheme(next);
  }

  return (
    <button type="button" className="cursor-pointer text-muted transition-colors hover:text-ink" onClick={toggle} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} mode`}>
      {theme === "dark" ? "light mode" : "dark mode"}
    </button>
  );
}
