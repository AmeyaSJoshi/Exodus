import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "EGRESS Admin",
  description: "Live building state for the EGRESS evacuation prototype",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen antialiased">{children}</body>
    </html>
  );
}
