import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, Hanken_Grotesk, JetBrains_Mono } from "next/font/google";
import "./globals.css";

// The fonts, downloaded at build time and served with the site (no request to Google from a visitor's browser).
const display = Bricolage_Grotesque({ subsets: ["latin"], weight: ["500", "700"], variable: "--font-display" });
const body = Hanken_Grotesk({ subsets: ["latin"], weight: ["400", "500", "600"], variable: "--font-body" });
const mono = JetBrains_Mono({ subsets: ["latin"], weight: ["400", "600"], variable: "--font-mono" });

export const metadata: Metadata = {
  metadataBase: new URL("https://pond.camera"),
  title: "Pond: every camera, recorded on your Mac",
  description:
    "Pond records your IP cameras around the clock to a drive you choose, finds what happened in plain words, and puts each camera in Apple’s Home app. Your footage never leaves the house.",
  openGraph: {
    title: "Pond",
    description: "Every camera, recorded on your Mac.",
    url: "https://pond.camera",
    siteName: "Pond",
    type: "website",
  },
};

export const viewport: Viewport = {
  viewportFit: "cover",
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#0d1315" },
    { media: "(prefers-color-scheme: light)", color: "#eef3f3" },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
