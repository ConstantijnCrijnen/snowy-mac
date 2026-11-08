# A winter desktop

The page is a small working desktop, rather than a conventional stack of marketing sections. The visitor can understand the product by moving a real window through its snow, then download the Mac app.

The supplied reference sets the nostalgic interface direction. Snowy uses original brushed chrome, Aqua controls, a dark blue winter desktop and functional windows; it does not reuse the reference's screenshots, media, brand or layout. The main download lives inside an About window. Weather and Read me are working companion windows. The Dock is a physical surface and a way to recover closed windows.

## Visual choices

- Midnight `#102c4c`, cloud `#f5f8fa`, ink `#27323a`, steel `#aab9c4`, Aqua `#1761bc`, and paper `#fcfbf5`.
- Lucida/system interface type for the desktop; Helvetica Neue for the wordmark; Georgia only for the paper note.
- Chrome, controls and icons carry the nostalgia. The wallpaper and copy stay quiet.
- All icons and the wallpaper are original code-native SVG/CSS. No external stock media, generated pictures or borrowed application icons are required.

## Behavior

Title bars follow the pointer directly. Traffic lights hide/reopen or resize windows; every action changes the physical playground. Keyboard title bars and resize grips provide alternatives to dragging. Desktop windows overlap; phone windows start stacked in a scrollable arrangement. Explore/Sweep modes keep snow interaction from trapping ordinary touch scrolling.

One animation clock runs the snow. Main actions have immediate press feedback; opening windows uses a short, restrained opacity/scale transition. Dock icon feedback is local. Reduced Motion disables decorative falls and transition movement while retaining material interaction. Hidden tabs suspend work.

The Terminal accepts a small whitelist of commands. The seasonal defrost sound is a user-provided MP3, played only after an explicit click or Terminal command. It does not change the weather. Weather preferences are validated, saved locally when available, and fall back without breaking the desktop if storage is blocked.

## Validation

Native app verification remains headless. The user separately authorized an isolated headless browser for the website; it uses a temporary browser profile and never controls the user's desktop or launches Snowy. Browser evidence and temporary reports are excluded from Git. Physics regressions run with Node's built-in test runner; the browser has no runtime dependencies. The payment Worker uses Standard Webhooks for signature checks; no benchmarks are run.

One independent visual review of the initial light wallpaper scored it 8/10. It identified weak snow contrast, faint requirements text, and mobile text behind the Dock. The final direction follows the user's request for a dark classic-OS-X blue wallpaper, increases requirements text contrast/size, and shortens the instructions so their numbered content clears the mobile Dock. A second independent review of the final dark desktop and phone screenshots scored it 9/10, with no visual blockers. The remaining optional refinement is to simplify the mountain silhouettes so they echo the Aqua wallpaper arcs more closely. Three consecutive isolated browser runs cover the same desktop, phone, Reduced Motion and storage flows.

Both platform buttons open the Aqua price sheet, which suggests $2.99 and accepts $0. The Windows sheet offers an installer for most PCs and one for Windows on Arm. Positive download and wish-list amounts use same-origin checkout routes and Polar hosted payment. The return page verifies status on the server. The sheet explains that visitors can donate later. Instagram and TikTok link to archieauburn. The favicon reuses the same glossy Snowy artwork as the Dock.
