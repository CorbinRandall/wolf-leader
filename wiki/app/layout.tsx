import type { ReactNode } from 'react';
import { Provider } from '@/components/provider';
import './global.css';

export const metadata = {
  title: 'Wolf Leader Wiki',
  description: 'Living project knowledge generated from the Wolf Leader hub.',
};

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
