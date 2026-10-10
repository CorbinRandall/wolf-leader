'use client';
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  type SharedProps,
} from 'fumadocs-ui/components/dialog/search';
import { useDocsSearch, type SearchClient } from 'fumadocs-core/search/client';
import type { SortedResult } from 'fumadocs-core/search';
import { useMemo } from 'react';
import { hubUrl } from '@/lib/shared';

interface HubHit {
  kind: string;
  id: number;
  title?: string | null;
  content?: string | null;
  slug?: string | null;
  project_id?: number | null;
  project_slug?: string | null;
  created_at?: string | null;
  stamp?: string | null;
  path?: string | null;
  source?: string;
  similarity?: number;
}

// The hub computes the local-time stamp that names the howl page; fall back to UTC only if absent.
function stamp(hit: HubHit): string {
  if (hit.stamp) return hit.stamp;
  return (hit.created_at ?? '').slice(0, 16).replace('T', '-').replace(/:/g, '') || 'unknown';
}

/** Map a hub hit onto the wiki page that shows it. Unknown kinds fall back to the hub UI. */
function toResult(hit: HubHit, i: number): SortedResult {
  const base = `${hubUrl}`;
  const text = (hit.title ?? hit.content ?? `${hit.kind} #${hit.id}`).toString().slice(0, 160);
  const slug = hit.slug ?? hit.project_slug ?? null;
  switch (hit.kind) {
    case 'project':
      return { id: `p-${hit.id}-${i}`, type: 'page', url: `/docs/projects/${slug ?? hit.id}`, content: text };
    case 'howl':
      return {
        id: `h-${hit.id}-${i}`,
        type: 'heading',
        url: `/docs/howls/${slug ?? 'unknown'}/${stamp(hit)}`,
        content: text,
        breadcrumbs: slug ? [slug, 'howls'] : undefined,
      };
    case 'memory':
      return {
        id: `m-${hit.id}-${i}`,
        type: 'text',
        url: slug ? `/docs/projects/${slug}#what-we-know` : `${base}/?project=${hit.project_id ?? ''}`,
        content: text,
        breadcrumbs: slug ? [slug, 'memory'] : ['memory'],
      };
    case 'catalog':
    case 'chunk':
      return {
        id: `f-${hit.id}-${i}`,
        type: 'text',
        url: slug ? `/docs/projects/${slug}#where-it-lives` : `${base}/?project=${hit.project_id ?? ''}`,
        content: `${hit.path ?? text}`,
        breadcrumbs: [hit.kind === 'chunk' ? 'file body' : 'file'],
      };
    case 'chat':
    default:
      return { id: `c-${hit.id}-${i}`, type: 'text', url: `${base}/?chat=${hit.id}`, content: text, breadcrumbs: ['session'] };
  }
}

export default function HubSearchDialog(props: SharedProps) {
  // Hybrid keyword + pgvector search from the hub — same results as /wolfeat.
  const client = useMemo<SearchClient>(
    () => ({
      deps: [hubUrl],
      async search(query: string) {
        const url = new URL(`${hubUrl}/api/search`, window.location.origin);
        url.searchParams.set('q', query);
        url.searchParams.set('limit', '20');
        const res = await fetch(url);
        if (!res.ok) throw new Error(await res.text());
        const body = (await res.json()) as { results?: HubHit[] };
        return (body.results ?? []).map(toResult);
      },
    }),
    [],
  );
  const { search, setSearch, query } = useDocsSearch({ client, delayMs: 200 });

  return (
    <SearchDialog search={search} onSearchChange={setSearch} isLoading={query.isLoading} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput placeholder="Search projects, howls, memories, files…" />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList items={query.data !== 'empty' ? query.data : null} />
      </SearchDialogContent>
    </SearchDialog>
  );
}
