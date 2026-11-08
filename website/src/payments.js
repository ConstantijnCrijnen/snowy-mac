export const DOWNLOAD_URL =
  "https://github.com/soloiaros/snowy-mac/releases/latest/download/Snowy-macOS-arm64.dmg";
export const DOWNLOADS = Object.freeze({
  download: DOWNLOAD_URL,
  "windows-x64": "https://github.com/soloiaros/snowy-mac/releases/download/windows-v0.1.4.0/Snowy-Setup-x64.exe",
  "windows-arm64": "https://github.com/soloiaros/snowy-mac/releases/download/windows-v0.1.4.0/Snowy-Setup-arm64.exe",
});
export const MAX_AMOUNT_CENTS = 100_000;


// Parse a decimal string, not a floating-point dollar value. The server must
// repeat validation when checkout is connected; these checks are for the UI.
export function parseAmount(raw) {
  if (typeof raw !== "string") {
    return { ok: false, error: "Enter an amount in US dollars." };
  }
  const value = raw.trim();
  if (
    value.length > 16 ||
    !/^(?:\d+(?:\.\d{1,2})?|\.\d{1,2})$/.test(value)
  ) {
    return {
      ok: false,
      error: "Enter $0 or more, with up to two decimal places.",
    };
  }
  const [dollars, fraction = ""] = value.split(".");
  const cents = Number(dollars || "0") * 100 + Number(fraction.padEnd(2, "0"));
  if (!Number.isSafeInteger(cents) || cents > MAX_AMOUNT_CENTS) {
    return { ok: false, error: "Choose an amount from $0 to $1,000." };
  }
  return { ok: true, cents };
}

// Local intent only. The server validates all amounts again before checkout.
export function createPaymentIntent(raw, context = "download") {
  const isDownload = typeof context === "string" && Object.hasOwn(DOWNLOADS, context);
  if (!isDownload && context !== "support") {
    return { ok: false, error: "Choose whether to download or support Snowy." };
  }
  const amount = parseAmount(raw);
  if (!amount.ok) return amount;
  if (amount.cents === 0) {
    return isDownload
      ? { ok: true, kind: "download", url: DOWNLOADS[context] }
      : { ok: true, kind: "no-contribution" };
  }
  return {
    ok: true,
    kind: "checkout",
    amountCents: amount.cents,
    currency: "usd",
    context,
  };
}
