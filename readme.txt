tilecutter.pike:
---------------
Tilecutter is a tool for splitting a large source image
into a Zoomify or Deep Zoom tileset.

It was designed with a goal of having few limits as to
the maximum size of the image that could be processed,
and is less flexable than other tools that are restricted
to images which can be loaded into memory.

Input images should be in the NetPBM PNM format.
NetPBM is used for scaling.

merge.pike:
----------
Merge is a tool for merging a set of images into a composite
image.  I wrote it at a time when enblend/enfuse were broken
for large  images.

it is a quick and dirty replacement, using netPBM
to do the heavy lifting.

It should have no limitations on image size.

Input should be a file listing paths to TIFF input files,
ordered background to foreground.

stitch.sh:
---------
A quick script that uses netPBM to stitch a level from a
Deep Zoom tileset into a single image.
