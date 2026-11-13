import { FeatureParagraph, type Feature } from "./components/FeatureParagraph";
import { LaunchSplash } from "./components/LaunchSplash";
import { ThemeToggle } from "./components/ThemeToggle";
import { Wordmark } from "./components/Wordmark";

const REPO = "https://github.com/govijr/govi-terminal";
const RELEASES = `${REPO}/releases/latest`;

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

const gutter = "px-4 sm:px-8 lg:px-12";

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" className={className}>
      <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.72 1.22 1.87.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}

function DownloadIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M12 4v11M7 10l5 5 5-5M5 20h14" />
    </svg>
  );
}

export default function Home() {
  return (
    <div className="flex min-h-dvh flex-col">
      <LaunchSplash />

      <header className={`${gutter} flex h-14 items-center justify-end gap-6 text-sm ${intro}`}>
        {/* <a href={REPO} className="flex items-center gap-1.5 text-muted transition-colors hover:text-ink">
          <GitHubIcon className="size-4" />
          GitHub
        </a> */}
        <ThemeToggle />
      </header>

      <main
        className={`${gutter} mx-auto grid w-full max-w-[1440px] flex-1 items-center gap-10 py-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-16 lg:py-6`}
      >
        <div className="flex min-w-0 flex-col">
          {/* The splash wordmark lands here. */}
          <div className="hero-mark mb-6 block w-full max-w-[min(22rem,100%)] intro-pending:invisible">
            <Wordmark id="hero-wordmark" className="block h-auto w-full" />
          </div>

          <div className={intro}>
            {/* <p className="mb-5 inline-flex items-center gap-2 rounded-full border border-line px-3 py-1 text-xs text-muted">
              <span className="size-1.5 rounded-full bg-[var(--feat-git)]" aria-hidden="true" />
              Free and open source
            </p>

            <h1 className="text-[clamp(1.75rem,3.2vw,2.75rem)] leading-[1.1] font-semibold tracking-tight text-balance">
              The Mac terminal built for working with agents.
            </h1> */}
            <p className="mt-4 max-w-[34rem] text-[clamp(1rem,1.25vw,1.125rem)] leading-relaxed text-muted text-pretty">
            Delightful terminal for working with AI agents.
            </p>
          </div>

          <div className={`mt-6 text-[clamp(0.95rem,1.15vw,1.05rem)] leading-[1.75] delay-100 ${intro}`}>
            <FeatureParagraph features={features} />
          </div>

          <div className={`mt-8 flex flex-wrap items-center gap-3 delay-200 ${intro}`}>
            <a
              id="download"
              href={RELEASES}
              className="inline-flex h-11 items-center gap-2 rounded-lg bg-ink px-5 text-sm font-medium text-canvas transition-opacity hover:opacity-85"
            >
              <DownloadIcon className="size-4" />
              Download for macOS
            </a>
            <a
              href={REPO}
              className="inline-flex h-11 items-center gap-2 rounded-lg border border-line px-5 text-sm font-medium transition-colors hover:bg-surface"
            >
              <GitHubIcon className="size-4" />
              Star on GitHub
            </a>
          </div>
        </div>

        <div className={`min-w-0 delay-300 ${intro}`}>
          <video
            src="/govi-terminal-v3.mp4"
            autoPlay
            loop
            muted
            playsInline
            aria-label="Govi running agents in split panes"
            className="block w-full rounded-xl border border-line shadow-[0_24px_60px_-20px_rgb(0_0_0/0.35)]"
          />
        </div>
      </main>
    </div>
  );
}
