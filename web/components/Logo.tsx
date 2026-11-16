export function Logo({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <rect width="64" height="64" rx="16" fill="var(--fuchsia)" />
      <circle cx="32" cy="32" r="17" fill="none" stroke="#fff" strokeWidth="5" />
      <circle cx="32" cy="32" r="6" fill="#fff" />
      <circle cx="46" cy="18" r="5" fill="var(--amber)" />
    </svg>
  );
}

export function Arrow() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3 8h9M8.5 4l4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
