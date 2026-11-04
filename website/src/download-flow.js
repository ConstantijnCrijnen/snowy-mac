import { createPaymentIntent, parseAmount } from "./payments.js";

// The only release URL comes from payments.js. An amount never becomes a URL,
// HTML, or a checkout request. Positive intents stay local until Polar is ready.
export function setupDownloadFlow({ onOpen = () => {} } = {}) {
  const dialog = document.querySelector("#download-dialog");
  const trigger = document.querySelector("#download");
  const form = document.querySelector("#download-form");
  const amount = document.querySelector("#download-amount");
  const feedback = document.querySelector("#download-feedback");
  const free = document.querySelector("#download-free");
  const submit = document.querySelector("#download-submit");
  const presets = [...dialog.querySelectorAll("[data-amount]")];

  function message(element, text) {
    element.textContent = text;
    element.hidden = !text;
  }
  function updateAmount() {
    const parsed = parseAmount(amount.value);
    amount.removeAttribute("aria-invalid");
    message(feedback, "");
    free.hidden = true;
    submit.textContent = parsed.ok && parsed.cents > 0
      ? "Support & download"
      : "Download Snowy";
    for (const preset of presets)
      preset.setAttribute("aria-pressed", String(parsed.ok && parsed.cents === Number(preset.dataset.amount) * 100));
  }
  function download() {
    const intent = createPaymentIntent("0", "download");
    const link = document.createElement("a");
    link.href = intent.url;
    link.download = "Snowy-macOS-arm64.dmg";
    document.body.append(link);
    link.click();
    link.remove();
    dialog.close();
  }
  trigger.addEventListener("click", () => {
    if (dialog.open) return;
    onOpen();
    amount.value = "0";
    updateAmount();
    dialog.showModal();
    amount.focus({ preventScroll: true });
    amount.select();
  });
  for (const id of ["download-close", "download-cancel"])
    document.getElementById(id).addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => trigger.focus({ preventScroll: true }));
  amount.addEventListener("input", updateAmount);
  for (const preset of presets)
    preset.addEventListener("click", () => {
      amount.value = preset.dataset.amount;
      updateAmount();
    });
  free.addEventListener("click", download);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const intent = createPaymentIntent(amount.value, "download");
    if (!intent.ok) {
      amount.setAttribute("aria-invalid", "true");
      message(feedback, intent.error);
      amount.focus();
    } else if (intent.kind === "download") download();
    else {
      message(feedback, intent.message);
      free.hidden = false;
    }
  });

  const supportForm = document.querySelector("#support-form");
  const supportAmount = document.querySelector("#support-amount");
  const supportFeedback = document.querySelector("#support-feedback");
  supportAmount.addEventListener("input", () => {
    supportAmount.removeAttribute("aria-invalid");
    message(supportFeedback, "");
  });
  supportForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const intent = createPaymentIntent(supportAmount.value, "support");
    if (!intent.ok) {
      supportAmount.setAttribute("aria-invalid", "true");
      message(supportFeedback, intent.error);
      supportAmount.focus();
    } else {
      message(supportFeedback, intent.kind === "no-contribution"
        ? "No contribution needed. Enjoy the snow — following along means a lot."
        : intent.message);
    }
  });
}
