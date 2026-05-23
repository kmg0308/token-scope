# UI Research Notes

Research was checked on 2026-05-23.

## Sources

- Apple Human Interface Guidelines, windows: https://developer.apple.com/design/human-interface-guidelines/windows
- Apple Human Interface Guidelines, layout: https://developer.apple.com/design/human-interface-guidelines/layout
- Apple Human Interface Guidelines, buttons: https://developer.apple.com/design/human-interface-guidelines/buttons
- Apple Human Interface Guidelines, toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Apple Human Interface Guidelines, sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple Human Interface Guidelines, accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
- Apple Developer, Meet Liquid Glass: https://developer.apple.com/videos/play/wwdc2025/219/
- Apple Developer, Get to know the new design system: https://developer.apple.com/videos/play/wwdc2025/356/
- Apple Developer, SwiftUI updates: https://developer.apple.com/documentation/updates/swiftui
- OpenAI Help Center, ChatGPT macOS app screenshot tool: https://help.openai.com/en/articles/9295245-chatgpt-macos-app-screenshot-tool
- OpenAI Help Center, ChatGPT macOS launcher: https://help.openai.com/en/articles/9295241-accessing-the-launcher-chatgpt-macos-app
- Anthropic Help Center, install Claude Desktop: https://support.claude.com/en/articles/10065433-installing-claude-for-desktop
- Apple App Store, Claude by Anthropic: https://apps.apple.com/us/app/claude/id6473753684
- Apple App Store, Grok by xAI: https://apps.apple.com/us/app/grok-ai-assistant/id6670324846
- Sparkle documentation: https://sparkle-project.github.io/documentation/
- GitHub Releases REST API: https://docs.github.com/rest/reference/releases
- OpenAI usage dashboard help: https://help.openai.com/en/articles/10478918-api-usage-dashboard
- Claude Console usage reporting: https://support.claude.com/en/articles/9534590-cost-and-usage-reporting-in-the-claude-console
- LangSmith cost tracking: https://docs.langchain.com/langsmith/cost-tracking
- Langfuse metrics overview: https://langfuse.com/docs/metrics/overview

## Design Decisions

- Use a normal macOS app window because the dashboard needs enough room for charts, tables, and update controls.
- Keep the app visible in the Dock and app switcher so users can return to it like a regular utility app.
- Treat Liquid Glass as the navigation and control layer, not as a finish to paint over every table or chart. Apple warns that glass on content and glass on glass can muddy hierarchy.
- Use regular glass-like controls and material-backed content cards. On macOS 26, control chrome can adopt SwiftUI `glassEffect`; on older macOS versions it falls back to translucent system material.
- Use a Grok-adjacent tone: black graphite workspace, sharp white text, electric cyan action color, and sparse mint/violet ambient light only where it helps glass read as transparent.
- Liquid Glass must be visible in the product, not just present in code. The header and primary controls should read as a floating glass command layer above the dashboard.
- Use rounded rectangles for small and medium macOS controls. Reserve capsules for primary actions where extra emphasis is useful.
- Keep button targets at or above the macOS accessibility minimum of 28x28 pt; compact icon controls are 30x30 pt and regular controls are 34 pt tall.
- Prefer symbols in compact controls and buttons where the action is familiar. Use text labels for actions that are easy to misread.
- Use time range and bucket controls as first-class controls because the product's main job is time-based inspection.
- Use separate Codex and Claude Code areas because their token fields differ.
- Keep one All view for combined totals; direct comparison is handled through the All chart rather than a separate tab.
- Make one chart the center of the screen. Apple recommends keeping charts simple and revealing additional detail gradually.
- Hide tables behind Details because exact values are useful but should not dominate the first view.
- Borrow the current AI app feel through restraint: quiet dark surfaces, low-saturation controls, clear command grouping, strong content hierarchy, and no brand-specific copying from ChatGPT, Claude, or Grok.
- Avoid dated AI-looking visual patterns: no oversized hero text, no gradient blobs, no decorative cards, no vague copy, no saturated palette.
