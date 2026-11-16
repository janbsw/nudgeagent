"use client";

import { useEffect, useState } from "react";

type State = "anchored" | "excursion" | "drifting";

const HOPS: { app: string; detail: string; state: State; label: string }[] = [
  { app: "Keynote", detail: "Pitch deck.key", state: "anchored", label: "In your deck" },
  { app: "google.com", detail: "“fintech seed rounds DACH 2026”", state: "excursion", label: "Matches your goal" },
  { app: "techcrunch.com", detail: "Funding roundup, week 46", state: "excursion", label: "Still plausible" },
  { app: "youtube.com", detail: "“Ten desk setups that changed my life”", state: "drifting", label: "4 min, no link to the deck" },
];

// Step durations in ms: one per hop, then the nudge, then the return.
const STEPS = [1900, 2100, 2100, 2200, 4200, 2600];

const STATE_NAME: Record<State, string> = {
  anchored: "Anchored",
  excursion: "Excursion",
  drifting: "Drifting",
};

export function HeroTrip() {
  const [step, setStep] = useState(0);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    let t: ReturnType<typeof setTimeout>;
    if (mq.matches) {
      // No replay: show the nudge as a still frame.
      t = setTimeout(() => setStep(4), 0);
      return () => clearTimeout(t);
    }
    let s = 0;
    const tick = () => {
      t = setTimeout(() => {
        s = (s + 1) % STEPS.length;
        setStep(s);
        tick();
      }, STEPS[s]);
    };
    tick();
    return () => clearTimeout(t);
  }, []);

  const visibleHops = HOPS.slice(0, Math.min(step + 1, HOPS.length));
  const returned = step === 5;
  const nudging = step === 4;
  const current: State = returned ? "anchored" : HOPS[Math.min(step, HOPS.length - 1)].state;

  return (
    <div className="trip" data-state={current} aria-label="Example: a short trip away from a pitch deck, and the nudge back" role="img">
      <div className="trip-bar">
        <span className="trip-bar-dots" aria-hidden="true"><i /><i /><i /></span>
        <span className="trip-bar-right">
          <span className="trip-target" aria-hidden="true" />
          <span className="trip-time">1h 52m left</span>
        </span>
      </div>

      <div className="trip-goal">
        <span className="mono-label">Goal</span>
        <span>Finish the pitch deck by 5pm</span>
      </div>

      <ol className="trip-hops">
        {visibleHops.map((h, i) => (
          <li key={h.app} className={`hop hop-${h.state}`}>
            <span className="hop-line" aria-hidden="true" />
            <span className="hop-dot" aria-hidden="true" />
            <span className="hop-body">
              <span className="hop-app">{h.app}</span>
              <span className="hop-detail">{h.detail}</span>
            </span>
            <span className="hop-chip">{i === visibleHops.length - 1 && !returned ? STATE_NAME[h.state] : h.label}</span>
          </li>
        ))}
        {returned && (
          <li className="hop hop-anchored hop-return">
            <span className="hop-line" aria-hidden="true" />
            <span className="hop-dot" aria-hidden="true" />
            <span className="hop-body">
              <span className="hop-app">Keynote</span>
              <span className="hop-detail">Back on slide 7</span>
            </span>
            <span className="hop-chip">Anchored</span>
          </li>
        )}
      </ol>

      <div className={`nudge-card${nudging ? " is-in" : ""}`} aria-hidden={!nudging}>
        <p className="nudge-title">Still on the pitch deck?</p>
        <p className="nudge-text">1h 52m left. Slide 7 was where you stopped.</p>
        <div className="nudge-actions">
          <span className="nudge-btn nudge-primary">Back to Keynote</span>
          <span className="nudge-btn">This is relevant</span>
          <span className="nudge-btn">Snooze 10 min</span>
        </div>
      </div>
    </div>
  );
}
