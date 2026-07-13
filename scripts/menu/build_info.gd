extends RefCounted
## The build stamp shown on the main menu.
##
## CI rewrites BUILD to the short commit sha at export time (see deploy-pages.yml). It exists so a
## player can say WHICH build they are running instead of us guessing whether a browser served them
## a stale one — "it's not doing that" and "you're on an old build" look identical otherwise.
const BUILD := "dev"
