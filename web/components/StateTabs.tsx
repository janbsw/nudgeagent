"use client";

import { useRef, useState, type KeyboardEvent } from "react";

const STATES = [
  {
    id: "anchored",
    name: "Anchored",
    does: "Stays quiet",
    text: "You are in your output or one of its sources. The deck, the CRM, the doc you are writing. Nudge Agent leaves you alone.",
    example: ["Keynote · Pitch deck.key", "attio.com · Leads list"],
  },
  {
    id: "excursion",
    name: "Excursion",
    does: "Keeps watching, still quiet",
    text: "You left, but it still looks like work. A search that matches your goal, a page you copy from. Every trip gets about three minutes of grace.",
    example: ["google.com · “seed rounds DACH”", "Copied a number, deck changed"],
  },
  {
    id: "drifting",
    name: "Drifting",
    does: "Starts the gentle nudges",
    text: "The trip has lost its link to the goal. After a few sustained minutes, the menu bar icon changes color. Then, if needed, a friendly question.",
    example: ["youtube.com · desk setups", "4 min away, no edits"],
  },
] as const;

export function StateTabs() {
  const [active, setActive] = useState(0);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const s = STATES[active];

  const onKey = (e: KeyboardEvent) => {
    const dir = e.key === "ArrowDown" || e.key === "ArrowRight" ? 1 : e.key === "ArrowUp" || e.key === "ArrowLeft" ? -1 : 0;
    if (!dir) return;
    e.preventDefault();
    const next = (active + dir + STATES.length) % STATES.length;
    setActive(next);
    tabs.current[next]?.focus();
  };

  return (
    <div className="states">
      <div className="states-list" role="tablist" aria-label="The three states of a trip" aria-orientation="vertical" onKeyDown={onKey}>
        {STATES.map((st, i) => (
          <button
            key={st.id}
            ref={(el) => { tabs.current[i] = el; }}
            role="tab"
            id={`tab-${st.id}`}
            aria-selected={i === active}
            aria-controls={`panel-${st.id}`}
            tabIndex={i === active ? 0 : -1}
            className={`state-word state-${st.id}`}
            onClick={() => setActive(i)}
          >
            {st.name}
          </button>
        ))}
      </div>

      <div className={`state-panel state-panel-${s.id}`} role="tabpanel" id={`panel-${s.id}`} aria-labelledby={`tab-${s.id}`} key={s.id}>
        <div className="state-visual" aria-hidden="true">
          <span className="state-orb" />
          <span className="state-does">{s.does}</span>
        </div>
        <ul className="state-examples">
          {s.example.map((e) => (
            <li key={e}>{e}</li>
          ))}
        </ul>
        <p className="state-text">{s.text}</p>
      </div>
    </div>
  );
}
