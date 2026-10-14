import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { appName } from './shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="inline-flex items-center gap-2 font-extrabold tracking-tight">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden>
            <path
              d="M3 3 7 17 12 21 17 17 21 3 15 8 12 6 9 8Z M7 12l5 4 5-4M12 16v5"
              stroke="currentColor"
              strokeWidth="1.6"
            />
          </svg>
          {appName}
        </span>
      ),
      // The name in the top-left corner goes to the wiki's front page.
      url: '/',
    },
    links: [
      { text: 'Projects', url: '/docs/projects', active: 'nested-url' },
      { text: 'Howls', url: '/docs/howls', active: 'nested-url' },
      { text: 'Topics', url: '/docs/topics', active: 'nested-url' },
    ],
  };
}
