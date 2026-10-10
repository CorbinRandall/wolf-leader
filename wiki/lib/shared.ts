export const appName = 'Wolf Leader';
export const docsRoute = '/docs';

// The hub that serves this wiki at /wiki. Same origin in production; override
// for `next dev` with NEXT_PUBLIC_WOLF_HUB_URL=http://wolf.local:6971.
export const hubUrl = process.env.NEXT_PUBLIC_WOLF_HUB_URL ?? '';
