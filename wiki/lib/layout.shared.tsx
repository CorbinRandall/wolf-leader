import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { appName, hubUrl } from './shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="inline-flex items-center gap-2 font-extrabold tracking-tight">
          <span
            aria-hidden
            className="inline-block size-3 rounded-full"
            style={{ background: 'var(--color-fd-primary)' }}
          />
          {appName}
        </span>
      ),
      url: '/docs',
    },
    links: [
      { text: 'Projects', url: '/docs/projects', active: 'nested-url' },
      { text: 'Howls', url: '/docs/howls', active: 'nested-url' },
      { text: 'Topics', url: '/docs/topics', active: 'nested-url' },
      { text: 'Hub', url: `${hubUrl || ''}/`, external: true },
    ],
  };
}
