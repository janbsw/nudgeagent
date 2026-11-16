import { cacheLife } from "next/cache";

const REPO = "janbsw/nudgeagent";
export const RELEASES_PAGE = `https://github.com/${REPO}/releases`;

export type Download = {
  /** Direct link to the installer, or the releases page if none was found. */
  href: string;
  /** Version without the leading "v", for example "0.1.1". Null when unknown. */
  version: string | null;
};

type GitHubRelease = {
  tag_name: string;
  draft: boolean;
  html_url: string;
  assets: { name: string; browser_download_url: string }[];
};

/**
 * Newest published release, pre-releases included (GitHub's "latest" skips those).
 * Prefers the .dmg, then a .zip. Falls back to the releases page on any failure.
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

    const asset =
      release.assets.find((a) => a.name.endsWith(".dmg")) ?? release.assets.find((a) => a.name.endsWith(".zip"));

    return {
      href: asset?.browser_download_url ?? release.html_url,
      version: release.tag_name.replace(/^v/, ""),
    };
  } catch {
    return { href: RELEASES_PAGE, version: null };
  }
}
