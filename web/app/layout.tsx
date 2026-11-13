import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Govi Terminal",
  description:
    "Govi is a free, open-source macOS terminal built on Ghostty, with workspaces, worktrees, tasks and agents.",
};

// Runs before first paint: applies a saved theme and marks JS as available (so the splash
// is hidden without JS). The splash plays on every load.
const earlyScript = `(function(){var d=document.documentElement;try{var t=localStorage.getItem('govi-theme');if(t==='light'||t==='dark')d.dataset.theme=t;}catch(e){}d.dataset.js='';})();`;

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning className={`${geistSans.variable} ${geistMono.variable}`}>
      <head>
        <script dangerouslySetInnerHTML={{ __html: earlyScript }} />
      </head>
      <body className="m-0 bg-canvas font-sans text-ink antialiased transition-colors duration-300 motion-reduce:transition-none">
        {children}
      </body>
    </html>
  );
}
