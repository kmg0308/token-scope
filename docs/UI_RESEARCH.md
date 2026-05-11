# UI Research Notes

Research was checked on 2026-05-11.

## Sources

- Apple Human Interface Guidelines, windows: https://developer.apple.com/design/human-interface-guidelines/windows
- Sparkle documentation: https://sparkle-project.github.io/documentation/
- GitHub Releases REST API: https://docs.github.com/rest/reference/releases
- OpenAI usage dashboard help: https://help.openai.com/en/articles/10478918-api-usage-dashboard
- Claude Console usage reporting: https://support.claude.com/en/articles/9534590-cost-and-usage-reporting-in-the-claude-console
- LangSmith cost tracking: https://docs.langchain.com/langsmith/cost-tracking
- Langfuse metrics overview: https://langfuse.com/docs/metrics/overview

## Design Decisions

- Use a normal macOS app window because the dashboard needs enough room for charts, tables, and update controls.
- Keep the app visible in the Dock and app switcher so users can return to it like a regular utility app.
- Use time range and bucket controls as first-class controls because the product's main job is time-based inspection.
- Use separate Codex and Claude Code areas because their token fields differ.
- Keep one All view for combined totals; direct comparison is handled through the All chart rather than a separate tab.
- Make one chart the center of the screen. Apple recommends keeping charts simple and revealing additional detail gradually.
- Hide tables behind Details because exact values are useful but should not dominate the first view.
- Avoid AI-looking visual patterns: no oversized hero text, no gradient blobs, no decorative cards, no vague copy, no saturated palette.
