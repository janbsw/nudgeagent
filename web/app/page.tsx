import { Nav } from "@/components/Nav";
import { HeroTrip } from "@/components/HeroTrip";
import { StateTabs } from "@/components/StateTabs";
import { ProfileTabs } from "@/components/ProfileTabs";
import { Arrow, Logo } from "@/components/Logo";

const LADDER = [
  { title: "The icon changes color", text: "A quiet signal in your menu bar. Many people notice it and come back on their own." },
  { title: "A short notification", text: "“Still on the lead search? 2h left.” One line, no lecture." },
  { title: "A floating card", text: "With one button that brings your deck, doc or tab straight back to the front." },
  { title: "Sound or a stronger card", text: "Only if you switch it on. Some days need a louder friend." },
];

const PRIVACY = [
  { title: "Screenshots stay in memory", text: "Only the active window, only when a window is unclear, never written to disk." },
  { title: "Some apps are never looked at", text: "Password managers, banking, Messages, WhatsApp and private windows are always skipped. Add your own." },
  { title: "Your clipboard stays yours", text: "It counts that you copied something. It never reads what." },
  { title: "No server in between", text: "Everything runs on your Mac. Only short descriptions of the current window go to the AI model." },
];

const FAQ = [
  {
    q: "Is this a website blocker?",
    a: "No. Nothing is blocked and there is no list of bad sites. YouTube can be research for one goal and drift for another. Nudge Agent judges each trip against the goal you set.",
  },
  {
    q: "What if it nudges me while I am actually working?",
    a: "Press “This is relevant”. It remembers that for the current goal and will not ask about it again. Every nudge also offers Snooze and Take a break.",
  },
  {
    q: "Does it record my screen?",
    a: "No recording. Most of the time it reads app names, window titles and the browser address. Only when that is not enough does it look at the active window, reads the text on your Mac, and forgets the image.",
  },
  {
    q: "Which Macs does it run on?",
    a: "macOS 14 or later. It needs Accessibility, Screen Recording, Automation for your browser and Notifications. The setup explains each one in plain words.",
  },
  {
    q: "What does it cost?",
    a: "Right now it is a team build and you bring your own Anthropic API key, stored in your Keychain. A typical day uses around 50 to 100 small text checks.",
  },
  {
    q: "What happens during meetings and breaks?",
    a: "It pauses. Zoom, Teams or Meet in front, a locked screen, idle time or the break button all stop the clock.",
  },
];

export default function Home() {
  return (
    <>
      <a href="#main" className="skip">Skip to content</a>
      <Nav />

      <main id="main">
        {/* Hero */}
        <section className="hero" id="top" aria-labelledby="hero-title">
          <div className="hero-card">
            <div className="hero-copy">
              <p className="eyebrow eyebrow-light">A Mac menu bar app for ADHD brains</p>
              <h1 id="hero-title" className="hero-title">
                One goal.
                <br />
                Gentle nudges back.
              </h1>
              <p className="hero-lede">
                Tell it what you want to get done. When a quick search turns into twenty minutes of something else, it notices
                and offers a friendly way back. No judgement, ever.
              </p>
              <div className="hero-ctas">
                <a href="#download" className="btn btn-light">Download for Mac</a>
                <a href="#states" className="btn btn-ink">See how it works</a>
              </div>
            </div>

            <div className="hero-demo">
              <HeroTrip />
            </div>

            <ul className="hero-facts">
              <li><span className="fact-dot" aria-hidden="true" />Lives in your menu bar</li>
              <li><span className="fact-dot" aria-hidden="true" />Screenshots are never stored</li>
              <li><span className="fact-dot" aria-hidden="true" />Asks before it assumes</li>
            </ul>
          </div>
        </section>

        {/* States */}
        <section className="section" id="states" aria-labelledby="states-title">
          <div className="container">
            <p className="eyebrow">Trips, not tabs</p>
            <h2 id="states-title" className="h2 h2-narrow">Leaving your work is fine. It watches where the trip goes.</h2>
            <StateTabs />
          </div>
        </section>

        {/* Problem / answer */}
        <section className="section section-tight" aria-labelledby="why-title">
          <div className="container">
            <h2 id="why-title" className="h2">Why Nudge Agent</h2>
            <div className="why">
              <article className="why-card why-problem">
                <p className="why-label">The problem</p>
                <h3 className="h3">Timers and blockers don&rsquo;t know your task.</h3>
                <p>
                  A blocker can&rsquo;t tell research from a rabbit hole. A timer rings whether you are deep in it or long gone. And
                  most focus apps treat drifting like a failure, which is the fastest way to make you close them.
                </p>
              </article>
              <article className="why-card why-answer">
                <p className="why-label">The answer</p>
                <h3 className="h3">It knows what you are working on, and asks kindly.</h3>
                <p>
                  Each goal gets its own picture of what working looks like: the output, the sources, the tools. A trip is
                  judged as a whole, from where it started to whether your work changed when you came back. When you have
                  really wandered off, it offers the way back.
                </p>
              </article>
            </div>
          </div>
        </section>

        {/* Goal to profile */}
        <section className="section" id="goal" aria-labelledby="goal-title">
          <div className="container goal">
            <div className="goal-copy">
              <p className="eyebrow">Goal setup</p>
              <h2 id="goal-title" className="h2">Write one sentence. Get a plan.</h2>
              <p className="lede">
                Type your goal the way you would say it. Nudge Agent sketches what working on it looks like. Change anything that
                looks off, then start.
              </p>
              <ul className="goal-points">
                <li>Counts toward a target, like 20 leads or 30 emails</li>
                <li>Knows your deadline and tells you how much time is left</li>
                <li>Works for decks, research, inbox days, outreach and reading</li>
              </ul>
            </div>
            <ProfileTabs />
          </div>
        </section>

        {/* Ladder */}
        <section className="section section-tight" aria-labelledby="ladder-title">
          <div className="container">
            <p className="eyebrow">When you drift</p>
            <h2 id="ladder-title" className="h2 h2-narrow">It starts with a whisper.</h2>
            <ol className="ladder">
              {LADDER.map((s, i) => (
                <li key={s.title} className="rung" style={{ ["--i" as string]: i }}>
                  <span className="rung-step">Step {i + 1}</span>
                  <h3 className="rung-title">{s.title}</h3>
                  <p>{s.text}</p>
                </li>
              ))}
            </ol>
            <p className="ladder-note">
              Every nudge offers <strong>This is relevant</strong>, <strong>Snooze</strong> and <strong>Take a break</strong>.
              Your answers make the next nudge smarter.
            </p>
          </div>
        </section>

        {/* Extras */}
        <section className="section section-tight" aria-labelledby="extras-title">
          <div className="container">
            <h2 id="extras-title" className="h2">Small things that help a lot</h2>
            <div className="extras">
              <article className="extra">
                <div className="extra-keys" aria-label="Shortcut Control Option P">
                  <kbd>⌃</kbd><kbd>⌥</kbd><kbd>P</kbd>
                </div>
                <h3 className="h3-sm">Parking lot</h3>
                <p>A thought pops up mid-task. Park it in two seconds and keep going. It waits for you in the recap.</p>
              </article>
              <article className="extra">
                <div className="extra-progress" aria-hidden="true">
                  <span className="extra-count">14</span>
                  <span className="extra-of">/ 20 leads</span>
                  <span className="extra-bar"><i style={{ width: "70%" }} /></span>
                </div>
                <h3 className="h3-sm">Progress you can see</h3>
                <p>Count goals tick up with <kbd>⌃</kbd><kbd>⌥</kbd><kbd>=</kbd>. Seeing 14 of 20 is a nudge too.</p>
              </article>
              <article className="extra">
                <div className="extra-recap" aria-hidden="true">
                  <span><b>2h 10m</b> focused</span>
                  <span><b>3</b> trips that drifted</span>
                </div>
                <h3 className="h3-sm">A recap, not a report card</h3>
                <p>Where your attention went, said plainly. Then a suggestion for what to pick up next.</p>
              </article>
            </div>
          </div>
        </section>

        {/* Privacy */}
        <section className="section" id="privacy" aria-labelledby="privacy-title">
          <div className="container">
            <div className="privacy">
              <div className="privacy-copy">
                <h2 id="privacy-title" className="h2">Stays on your Mac</h2>
                <p className="lede">
                  Something that watches your screen has to earn trust. So it looks as little as it can, and keeps even less.
                </p>
              </div>
              <ul className="privacy-list">
                {PRIVACY.map((p) => (
                  <li key={p.title}>
                    <h3 className="h3-sm">{p.title}</h3>
                    <p>{p.text}</p>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        </section>

        {/* FAQ */}
        <section className="section section-tight" id="faq" aria-labelledby="faq-title">
          <div className="container faq">
            <h2 id="faq-title" className="h2">Questions</h2>
            <div className="faq-list">
              {FAQ.map((f) => (
                <details key={f.q} className="faq-item">
                  <summary>
                    {f.q}
                    <span className="faq-icon" aria-hidden="true" />
                  </summary>
                  <p>{f.a}</p>
                </details>
              ))}
            </div>
          </div>
        </section>

        {/* CTA */}
        <section className="section section-tight" id="download" aria-labelledby="cta-title">
          <div className="container">
            <div className="cta">
              <h2 id="cta-title" className="cta-title">Pick one thing. We&rsquo;ll keep you near it.</h2>
              <p>Free while we test it as a team. macOS 14 or later.</p>
              <div className="hero-ctas">
                <a href="#download" className="btn btn-light">Download for Mac</a>
                <a href="#faq" className="btn btn-ghost">
                  Read the FAQ <Arrow />
                </a>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="container footer-inner">
          <a href="#top" className="brand" aria-label="Nudge Agent home">
            <Logo size={24} />
            <span>Nudge Agent</span>
          </a>
          <p>Made for brains that wander. © 2026</p>
        </div>
      </footer>
    </>
  );
}
