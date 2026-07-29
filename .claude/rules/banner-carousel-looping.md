# Banner And Carousel Looping

## Scope

This rule applies to every multi-item, swipeable activity, marketing, game, or resource banner/carousel. It applies whether the carousel is in a room, lobby, list, popup, or any future feature.

Static status, warning, error, and notification banners are not carousels and are excluded. Non-banner paged content, such as a gift grid or content tabs, is also excluded unless its product requirement explicitly makes it a circular carousel.

## Required behavior

- A user can swipe continuously in either direction: last item to first item and first item to last item must both work without a visible jump.
- Automatic advancement and manual paging must use the same cyclic state machine. Autoplay must not reset the logical item after a manual swipe.
- Pause autoplay for the duration of a manual swipe or manual page command. Resume only after the configured delay from the last manual interaction; each newer interaction must cancel the prior resume timer so autoplay cannot race the gesture.
- Detect a swipe at gesture start (for example, with a non-interfering simultaneous `DragGesture`), not only after `TabView` commits a new selection; selection-change handling still resets the resume delay at the completed page.
- Use first/last sentinel pages for multi-item SwiftUI `TabView(.page)` implementations. After reaching a sentinel, asynchronously reset selection to the corresponding real page with animations disabled.
- Keep physical pager selection separate from logical item index. Indicators, active-item decoration, and tap callbacks use the logical item, never a sentinel index.
- With one item, render only the item: do not add sentinel duplicates, a pager indicator, or an autoplay task.
- When carousel data changes, reset or clamp both selection states before autoplay continues.
- Keep the whole banner tappable without preventing horizontal swipe gestures.

## Verification

For every new or changed carousel, verify with one, two, and three items. Confirm manual last-to-first and first-to-last swipes, autoplay wraparound, the active indicator/content mapping, tap behavior, and replacement data while the carousel is visible.
