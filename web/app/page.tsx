import { FeatureParagraph, type Feature } from "./components/FeatureParagraph";
import { LaunchSplash } from "./components/LaunchSplash";
import { ThemeToggle } from "./components/ThemeToggle";
import { Wordmark } from "./components/Wordmark";

// `token` maps to a --feat-* color defined in globals.css (light and dark).
const features: Feature[] = [
  {
    name: "Workspaces",
    token: "workspaces",
    detail: "split panes you can drag and snap, saved projects, reusable templates, and a Finder service that opens one here",
    icon: (<><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M12 4v16" /></>),
  },
  {
    name: "Session recovery",
    token: "recovery",
    detail: "terminals that keep running after you quit Govi, reopened or ended from Settings",
    icon: (<><path d="M3 12a9 9 0 1 0 2.6-6.4L3 8" /><path d="M3 3v5h5" /></>),
  },
  {
    name: "Agents",
    token: "agents",
    detail: "launch Claude Code, Codex, Cursor, Pi, Grok or OpenCode in a split, resume past sessions, and see which one is working",
    icon: (<><path d="M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8z" /><path d="M19 16l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" /></>),
  },
  {
    name: "Attention queue",
    token: "attention",
    detail: "a notifications list for agents that need input or have finished, a Dock badge count, and a shortcut to jump to the next one",
    icon: (<><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" /><path d="M10.3 21a1.9 1.9 0 0 0 3.4 0" /></>),
  },
  {
    name: "Tasks",
    token: "tasks",
    detail: "GitHub and Linear issues turned into editable briefs that start an agent in its own workspace",
    icon: (<><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M8 9l1.5 1.5L12.5 7.5M8 15h8" /></>),
  },
  {
    name: "Pull requests",
    token: "pulls",
    detail: "check results and review feedback at a glance, then create draft or regular pull requests and post comments",
    icon: (<><circle cx="6" cy="6" r="2.2" /><circle cx="6" cy="18" r="2.2" /><circle cx="18" cy="18" r="2.2" /><path d="M6 8.2v7.6M18 15.8V11a3 3 0 0 0-3-3h-3" /><path d="M14 5.5L12 8l2 2.5" /></>),
  },
  {
    name: "Git",
    token: "git",
    detail: "a changes panel with unified or side-by-side diffs, staging, commits, pushes, and worktree management",
    icon: (<><circle cx="6" cy="5" r="2" /><circle cx="6" cy="19" r="2" /><circle cx="18" cy="7" r="2" /><path d="M6 7v10M18 9c0 5-12 3-12 8" /></>),
  },
  {
    name: "Find and search",
    token: "find",
    detail: "find text in a terminal's output and search open terminals by name or folder",
    icon: (<><circle cx="11" cy="11" r="7" /><path d="M21 21l-4.3-4.3" /></>),
  },
  {
    name: "Command palette",
    token: "palette",
    detail: "a ⌘K palette for every action, plus shortcuts you can rebind with conflict checks",
    icon: (<path d="M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3" />),
  },
  {
    name: "Remote hosts",
    token: "remote",
    detail: "saved SSH hosts, ~/.ssh/config aliases, and Tailscale devices with online status, with no passwords or keys stored",
    icon: (<><rect x="3" y="4" width="18" height="7" rx="2" /><rect x="3" y="13" width="18" height="7" rx="2" /><path d="M7 7.5h.01M7 16.5h.01" /></>),
  },
  {
    name: "Inline suggestions",
    token: "suggest",
    detail: "dimmed zsh completions from your history and saved commands, accepted with Tab, with optional Jev ranking",
    icon: (<><path d="M5 4h4M15 4h4M5 20h4M15 20h4M12 4v16" /></>),
  },
  {
    name: "Themes",
    token: "themes",
    detail: "color themes, monospace fonts, spacing, cursor styles, window backgrounds, and a launch animation",
    icon: (<><circle cx="12" cy="12" r="9" /><circle cx="8" cy="10" r="1" fill="currentColor" /><circle cx="12" cy="7.5" r="1" fill="currentColor" /><circle cx="16" cy="10" r="1" fill="currentColor" /><circle cx="9" cy="15" r="1" fill="currentColor" /></>),
  },
  {
    name: "Tool splits",
    token: "splits",
    detail: "a code editor, browser, iPhone simulator, and macOS virtual machine in panes beside your terminal",
    icon: (<><path d="M4 17l6-6-6-6M12 19h8" /></>),
  },
];

// Page content waits for the wordmark to land, then rises in stages.
const intro =
  "transition duration-700 ease-out intro-pending:translate-y-3 intro-pending:opacity-0 motion-reduce:transition-none";

// Every size and gap is in vw, so the layout scales with the window and with browser zoom.
// The values are the original pixel design at a 1280px-wide window (1vw = 12.8px).
const block = `mb-[1.9vw] text-[1.72vw] leading-[1.6] ${intro}`;

export default function Home() {
  return (
    <div className="flex min-h-dvh flex-col">
      <LaunchSplash />

      <header className={`mx-[4.69vw] flex h-[8.75vw] items-center justify-end text-[1.33vw] ${intro}`}>
        <nav className="flex gap-[2.19vw]">
          <ThemeToggle />
        </nav>
      </header>

      {/* Content sits at the bottom of the window. */}
      <div className="flex flex-1 flex-col justify-end px-[4.69vw] max-w-[50vw]">
        <main>
          {/* The splash wordmark lands here, 15% smaller than it was drawn. */}
          <a
            href="#download"
            aria-label="govi terminal, download"
            className="hero-mark mt-[0.6vw] mb-[1.4vw] block w-full max-w-[34.5vw] intro-pending:invisible"
          >
            <Wordmark id="hero-wordmark" className="block h-auto w-full" />
          </a>

          <section className={block}>
            <span className="">
             The terminal you would get addicated.
            </span>
            <br/>
            {/* <br/> */}
            <FeatureParagraph features={features} />
          </section>

          <button className="w-full rounded-md bg-black px-[0.6vw] py-[0.6vw] text-[1.04vw] text-white dark:bg-white dark:text-black">
            Buy for $49
          </button>
        </main>

        <footer
          className={`mt-[3.5vw] flex w-full max-w-[39vw] justify-between pb-[3.75vw] text-[1.09vw] text-muted delay-300 ${intro}`}
        >
          <span>© 2026 govi</span>
          <span>built on ghostty</span>
        </footer>
      </div>
    </div>
  );
}
