import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  // Static export served by the Wolf Leader FastAPI app at /wiki.
  output: 'export',
  basePath: '/wiki',
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
};

export default withMDX(config);
