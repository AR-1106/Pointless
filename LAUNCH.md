# Launch day runbook

A compressed, chronological checklist for shipping Pointless 1.0.

## T-7 days · Soft launch

- [ ] Send the build to 10-20 people (friends, TestFlight-equivalent Sparkle pre-release channel).
- [ ] Run through onboarding on 3 different Macs (Apple silicon only, different macOS 26 point releases).
- [ ] Verify `Settings → Updates → Check for Updates` works with a bumped pre-release build.
- [ ] Record the 30-second demo video (native capture in QuickTime, trimmed to 30 s).
- [ ] Export demo-poster.jpg as the paused frame.

## T-2 days · Freeze + copy

- [ ] Feature freeze. Only bug fixes.
- [ ] Make sure `SUFeedURL` in `Info.plist` and `appcast.xml` point at the production URL.
- [ ] `./scripts/release.sh 1.0.0 1` produces a DMG. Smoke test: download, open, drag to Applications, launch, onboard, tap, scroll, quit, reopen.

## T-1 day · Pre-announce

- [ ] Queue tweets and threads (X/Bluesky).
- [ ] Draft Product Hunt submission (title, tagline, description, gallery, first comment).
- [ ] Draft Show HN post.
- [ ] Draft r/macapps post.
- [ ] Tell key influencers/journalists they'll see it tomorrow at 12:01 AM PT (PH convention).

## Launch day

### 00:01 PT

- [ ] Go live on Product Hunt.
- [ ] Post Show HN with the demo video link.
- [ ] Post to r/macapps.
- [ ] Pin a thread on X/Bluesky.

### First 4 hours

- [ ] Reply to every Product Hunt comment personally.
- [ ] Reply to every HN comment (answer technical questions honestly).
- [ ] Retweet / quote-tweet early adopters.

### Evening

- [ ] Email list blast with the demo video.
- [ ] Post a "thank you" wrap-up.

## Post-launch (next 2 weeks)

- [ ] Watch MetricKit crash reports daily.
- [ ] Aggregate the top 3 feedback themes.
- [ ] Ship 1.1 with the top 3 within 3 weeks of launch.
- [ ] Write a "what we shipped / what we learned" blog post.

## Contingency

- **Bug hits early:** tag a `1.0.1-hotfix`, run `./scripts/release.sh 1.0.1 2`, push via Sparkle. Pin a tweet.
- **Notarization fails:** fall back to ad-hoc signing + warning dialog on the landing page. Rerun `xcrun notarytool submit` with `--verbose`.
- **Server overloaded:** host the DMG on GitHub Releases as a backup.
