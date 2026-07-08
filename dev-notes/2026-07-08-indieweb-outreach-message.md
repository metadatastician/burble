<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Draft — IndieWeb community outreach message

**Status:** draft to send later (owner to sort out channel + fill placeholders).
**Date:** 2026-07-08
**Context:** Burble ↔ IndieWeb optional integration. See `docs/decisions/0002-indieweb-native-optional-integration.adoc` (the existing, sane, optional design — IndieAuth / `rel=me` / Micropub / Webmention) and `docs/decisions/0010-presence-discovery-and-trust-zones.adoc` (which elevates the `rel=me` graph into *verified* social identity). Tone goal: respectful fellow-traveller offering an optional extra — NOT a takeover / land-grab / competitor.

Fill in `[your name]` and `[your me-URL]` before sending.

---

## Long version (for a post on your own site, or a considered message)

**Subject: A small, optional idea that builds on the IndieWeb — would genuinely love your thoughts**

Hi all,

I'm a real fan of the IndieWeb — owning your own identity and connections, and the building blocks like IndieAuth, `rel=me`, microformats and Webmention, are exactly how I think the web ought to work. I wanted to share something and ask what you make of it, partly because it's relevant to your world and mostly because you'd know far better than I would whether it's any good.

I've been building a small personal project called **Burble** — peer-to-peer voice and chat with no central platform (you own the connection, not a company). One part of it is a presence/identity layer, and the idea I'm quietly excited about is this: your IndieWeb identity — your own domain, via IndieAuth / `rel=me` — could *optionally* become a verified, reachable way for people to reach you. The `rel=me` graph is already a lovely social-identity graph; this would just add a "cryptographically verified, and reachable if you choose to be" dimension on top, for anyone who fancied it. I've even sketched out how it might work, if that's of interest.

I want to be really clear about a few things, because the last thing I'd want is to come across the wrong way:

- **It builds *on* the existing blocks** (IndieAuth, `rel=me`, microformats) — it doesn't replace, reinvent, or compete with anything.
- **It's completely optional.** Nobody has to do anything, install anything, or change their site. If you never touch it, nothing changes for you.
- **It takes nothing from the IndieWeb and won't affect it.** It isn't a platform trying to absorb the community — just a possible, respectful extra, shared because I care about this stuff and thinking of you felt like the right thing to do.

I'm honestly not trying to plant a flag on anyone's work — I'd just love your candid thoughts. Tell me if I'm missing an obvious principle, reinventing a wheel that already exists, or about to step on a rake you've all stepped on before. Experiences, critiques, "we tried that and here's what happened" — all hugely welcome.

And if it's not of interest to anyone, that's genuinely fine — no harm done. I mostly wanted to offer it, and to hear what you think.

Thanks for everything the community has built — it's inspiring to build near it.

— [your name] / [your me-URL]

---

## Short version (for chat — lead with this + a link to the post)

> Hi all — longtime admirer of the IndieWeb (IndieAuth, `rel=me`, Webmention, the lot). I've built a small P2P voice/chat project, Burble, and sketched an *optional* way to let your IndieWeb identity (domain via IndieAuth/`rel=me`) be a verified, reachable presence — building on the existing blocks, taking nothing, competing with nothing, fully opt-in. Not trying to plant a flag on anyone's work, just genuinely curious what you think and whether I'm missing something obvious. Happy to share the write-up — and if it's not of interest, no worries at all! 🙂

---

## How to send it (suggestions)

- **Most on-brand:** post the long version on *your own site* and share the permalink in the IndieWeb chat. Using the IndieWeb to talk about an IndieWeb idea proves you walk the walk, and it's exactly the kind of thing the community appreciates.
- **In chat:** lead with the short version + the link; keep the long one as the linked post for anyone who wants depth.
- **Fill in** `[your name]` and `[your me-URL]` first.
- **Optional next step:** ask Claude to turn ADR-0002 + ADR-0010 into a friendly, plain-English public write-up (jargon stripped) that you could publish as the linked post.
- Tone can be dialled warmer or more concise — this is a starting point, not a final.
