import { cacheLife } from "next/cache";

const REPO = "janbsw/nudgeagent";
export const RELEASES_PAGE = `https://github.com/${REPO}/releases`;

export type Download = {
  /** Page of the newest release (download and install steps), or the releases list as fallback. */
  href: string;
  /** Version without the leading "v", for example "0.1.1". Null when unknown. */
  version: string | null;
};

type GitHubRelease = {
  tag_name: string;
  draft: boolean;
  html_url: string;
};

/**
 * Newest published release, pre-releases included (GitHub's "latest" skips those).
 * Links its release page, which carries the install steps. Falls back to the releases list.
 */
export async function getLatestDownload(): Promise<Download> {
  "use cache";
  cacheLife("hours");

  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=10`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "nudgeagent-website" },
    });
    if (!res.ok) return { href: RELEASES_PAGE, version: null };

    const releases = (await res.json()) as GitHubRelease[];
    const release = releases.find((r) => !r.draft);
    if (!release) return { href: RELEASES_PAGE, version: null };

    return {
      href: release.html_url,
      version: release.tag_name.replace(/^v/, ""),
    };
  } catch {
    return { href: RELEASES_PAGE, version: null };
  }
}
