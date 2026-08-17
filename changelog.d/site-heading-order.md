### Internal

- Fixed the marketing site's heading order so no page skips a heading level: the landing page's feature cards are now introduced by a visually-hidden `Features` heading (visible card titles keep their current size), and the API reference's "SPA fallback" is a proper subsection of "Static files" instead of a skipped level. A heading-order contract was added to the site's static-output tests.
