"use client";

import { useState } from "react";

type Row = [key: string, value: string];

const PROFILES: { id: string; label: string; goal: string; rows: Row[] }[] = [
  {
    id: "research",
    label: "Research",
    goal: "Find 20 qualified fintech leads in DACH and add them to Attio",
    rows: [
      ["output", "Attio"],
      ["sources", "LinkedIn profiles, Apollo, company sites"],
      ["tools", "Google Sheets"],
      ["drift", "LinkedIn feed, news, unrelated email"],
      ["target", "20 leads"],
      ["deadline", "today, 17:00"],
    ],
  },
  {
    id: "create",
    label: "Create",
    goal: "Finish the pitch deck draft before lunch",
    rows: [
      ["output", "Keynote · Pitch deck.key"],
      ["sources", "Financial model.xlsx, Notion notes"],
      ["tools", "Figma, Unsplash"],
      ["drift", "Slack, news, video sites"],
      ["target", "deck changes"],
      ["deadline", "today, 12:30"],
    ],
  },
  {
    id: "process",
    label: "Process",
    goal: "Get the inbox under 30 and file this month's expenses",
    rows: [
      ["output", "Mail, expense tool"],
      ["sources", "receipts folder, bank export"],
      ["tools", "Preview, Calculator"],
      ["drift", "reading without acting"],
      ["target", "items done"],
      ["deadline", "today, 16:00"],
    ],
  },
];

export function ProfileTabs() {
  const [active, setActive] = useState(0);
  const p = PROFILES[active];

  return (
    <div className="profile">
      <div className="profile-head">
        <div className="profile-tabs" role="tablist" aria-label="Example goals">
          {PROFILES.map((pr, i) => (
            <button
              key={pr.id}
              role="tab"
              aria-selected={i === active}
              aria-controls="profile-panel"
              className="profile-tab"
              onClick={() => setActive(i)}
            >
              {pr.label}
            </button>
          ))}
        </div>
      </div>

      <div className="profile-body" id="profile-panel" role="tabpanel" key={p.id}>
        <p className="profile-goal">
          <span className="profile-prompt" aria-hidden="true">›</span>
          {p.goal}
        </p>
        <dl className="profile-rows">
          {p.rows.map(([k, v]) => (
            <div key={k} className="profile-row">
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
        <div className="profile-foot">
          <span className="profile-check" aria-hidden="true">✓</span>
          Looks right? <strong>Start focus</strong>
        </div>
      </div>
    </div>
  );
}
