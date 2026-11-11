import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, Fira_Code } from "next/font/google";
import "./globals.css";

// The fonts (DESIGN.md), downloaded at build time and served with the site (no request to Google from a visitor's
// browser): Bricolage Grotesque for the wordmark alone, Fira Code for everything else.
const mark = Bricolage_Grotesque({ subsets: ["latin"], weight: ["700"], variable: "--font-mark" });
const code = Fira_Code({ subsets: ["latin"], weight: ["400", "500", "600"], variable: "--font-code" });

export const metadata: Metadata = {
  metadataBase: new URL("https://pond.camera"),
  title: "Pond: every camera, recorded on your Mac",
  description:
    "Pond records your IP cameras around the clock to your own drive, tells you what happened, and puts each camera in Apple’s Home app. Free, open source, and your footage never leaves the house.",
  openGraph: {
    title: "Pond",
    description: "Every camera, recorded on your Mac.",
    url: "https://pond.camera",
    siteName: "Pond",
    type: "website",
  },
  icons: { icon: "/mark.svg" },
};

export const viewport: Viewport = {
  viewportFit: "cover",
  themeColor: "#0b1419",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${mark.variable} ${code.variable}`}>
      <body>{children}</body>
    </html>
  );
}
