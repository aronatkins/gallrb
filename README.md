Really simple static image gallery generation.

The code is probably more complicated than it needs because it was originally run on an ancient server sitting in my basement and the Ruby performance (memory use and runtime) on that host was horrible. Replaced lots of Pathname to cut down the amount of object allocation.

I'm now running this on a more modern (faster) box, but haven't yet made a pass at simplifying the code.

Took some of the templating ideas from Rails.

Expects the ImageMagick/GraphicsMagick convert command. No other dependencies.