"use client";

import { useEffect, useState } from "react";
import { Logo } from "./Logo";

export function Nav({ downloadHref }: { downloadHref: string }) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className={`nav-wrap${scrolled ? " is-scrolled" : ""}`}>
      <nav className="nav" aria-label="Main">
        <a href="#top" className="brand" aria-label="Nudge Agent home">
          <Logo />
          <span>Nudge Agent</span>
        </a>
        <ul className="nav-links">
          <li><a href="#states">How it works</a></li>
          <li><a href="#goal">Goals</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href="#faq">FAQ</a></li>
        </ul>
        <a href={downloadHref} className="btn btn-ink btn-sm">Download for Mac</a>
      </nav>
    </header>
  );
}
