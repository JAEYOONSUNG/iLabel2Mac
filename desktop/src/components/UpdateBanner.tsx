import { useEffect, useState } from "react";
import type { UpdateOffer } from "../electron";

type Phase = "offer" | "downloading" | "ready" | "failed";

/* The update offer drawn in the app's own design: a small card in the corner,
   using the same tokens as every other panel, instead of an OS dialog parked
   over the canvas. Nothing downloads until the person says so. */
export default function UpdateBanner() {
  const [offer, setOffer] = useState<UpdateOffer | null>(null);
  const [phase, setPhase] = useState<Phase>("offer");
  const [percent, setPercent] = useState(0);
  const [error, setError] = useState("");
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    const updates = window.iLabelDesktop?.updates;
    if (!updates) return undefined;
    let cancelled = false;
    // the offer may have been announced before this component mounted
    void updates.state().then((existing) => {
      if (!cancelled && existing) setOffer(existing);
    });
    const offAvailable = updates.onAvailable((next) => {
      // A fresh offer restarts the conversation — phase state from an older
      // version's download must not leak into it.
      setOffer(next);
      setPhase("offer");
      setDismissed(false);
    });
    const offProgress = updates.onProgress((progress) => setPercent(progress?.percent ?? 0));
    return () => {
      cancelled = true;
      offAvailable();
      offProgress();
    };
  }, []);

  if (!offer || dismissed) return null;

  const updates = window.iLabelDesktop.updates;

  const download = async () => {
    setPhase("downloading");
    setPercent(0);
    const result = await updates.download();
    if (result.status === "success") {
      setPhase("ready");
    } else {
      setError(result.status === "error" ? result.error.message : "The download failed.");
      setPhase("failed");
    }
  };

  const skip = async () => {
    await updates.skip(offer.version);
    setDismissed(true);
  };

  const openDownloads = () => {
    void updates.openDownloads();
    setDismissed(true);
  };

  return (
    <aside className="update-banner" aria-live="polite" aria-label="Update available">
      {phase === "offer" && (
        <>
          <h4>iLabel Studio {offer.version} is available</h4>
          <p>
            You have {offer.current}.
            {offer.notes ? ` ${offer.notes}` : ""}
            {offer.self
              ? ""
              : " This copy cannot replace itself — download the new build and swap it in."}
          </p>
          <div className="update-actions">
            <button type="button" onClick={skip}>Skip</button>
            <button type="button" onClick={() => setDismissed(true)}>Later</button>
            {offer.self ? (
              <button type="button" className="primary" onClick={() => void download()}>
                Install Update
              </button>
            ) : (
              <button type="button" className="primary" onClick={openDownloads}>
                Open Downloads
              </button>
            )}
          </div>
        </>
      )}
      {phase === "downloading" && (
        <>
          <h4>Downloading {offer.version}…</h4>
          <div className="update-progress" role="progressbar" aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100}>
            <span style={{ width: `${Math.min(100, percent)}%` }} />
          </div>
          <p>{percent}% — it installs when you restart.</p>
        </>
      )}
      {phase === "ready" && (
        <>
          <h4>iLabel Studio {offer.version} is ready</h4>
          <p>Restart now to finish installing, or keep working — it installs when you quit.</p>
          <div className="update-actions">
            <button type="button" onClick={() => setDismissed(true)}>Later</button>
            <button type="button" className="primary" onClick={() => void updates.install()}>
              Restart Now
            </button>
          </div>
        </>
      )}
      {phase === "failed" && (
        <>
          <h4>The update could not be installed</h4>
          <p className="toast-error">{error}</p>
          <div className="update-actions">
            <button type="button" onClick={() => setDismissed(true)}>Close</button>
            <button type="button" className="primary" onClick={openDownloads}>
              Open Downloads
            </button>
          </div>
        </>
      )}
    </aside>
  );
}
