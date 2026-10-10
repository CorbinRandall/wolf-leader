import Link from 'next/link';
import { HomeLayout } from 'fumadocs-ui/layouts/home';
import { baseOptions } from '@/lib/layout.shared';
import { hubUrl } from '@/lib/shared';

const cards = [
  { href: '/docs', title: 'Home', body: 'Map of every project the pack knows about, newest howls first.' },
  { href: '/docs/projects', title: 'Projects', body: 'Living brief per project: where we left off, decisions, constraints, paths.' },
  { href: '/docs/howls', title: 'Howls', body: 'One page per broadcast — what landed, which machine, which commit.' },
  { href: '/docs/topics', title: 'Topics', body: 'Hubs built from tags and embedding neighbourhoods.' },
];

export default function HomePage() {
  return (
    <HomeLayout {...baseOptions()}>
      <main className="wl-hero flex flex-1 flex-col items-center justify-center px-6 py-16 text-center">
        <p className="mb-3 text-sm font-semibold uppercase tracking-[0.2em] text-fd-muted-foreground">
          Wolf Leader
        </p>
        <h1 className="mb-4 max-w-2xl text-4xl font-extrabold tracking-tight md:text-5xl">
          Everything the pack has learned, in one place.
        </h1>
        <p className="mb-10 max-w-xl text-fd-muted-foreground">
          Generated from Postgres on every save and howl. Search is the hub&apos;s hybrid keyword +
          vector search, so results match what <code>/wolfeat</code> returns.
        </p>
        <div className="grid w-full max-w-4xl gap-4 sm:grid-cols-2">
          {cards.map((c) => (
            <Link
              key={c.href}
              href={c.href}
              className="rounded-[var(--radius-lg)] border border-fd-border bg-fd-card p-6 text-left shadow-sm transition hover:-translate-y-0.5 hover:shadow-md"
            >
              <h2 className="mb-1 text-lg font-bold">{c.title}</h2>
              <p className="text-sm text-fd-muted-foreground">{c.body}</p>
            </Link>
          ))}
        </div>
        <a
          href={`${hubUrl}/`}
          className="mt-10 text-sm font-semibold text-fd-primary underline-offset-4 hover:underline"
        >
          Open the hub UI →
        </a>
      </main>
    </HomeLayout>
  );
}
