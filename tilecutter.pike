#! /usr/local/bin/pike
/*  Tilecutter.pike
    Copyright 2011 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
    This program takes a PNM format image, and splits it into a set
    of tiles usable with "deep zoom" based viewers, such as Seadragon.
*/

// Global Variables:

// Path to a temporary workspace
string TEMP_DIR = "";


/* 
   Generate a basic set of XML data for a seadragon deep zoom image.

   tile_size: Number of pixels on one side of a square tile
   overlap: Number of pixels by which tiles overlap
   format: Encoding format used for the tiles
   width: Width of the entire image
   height: Height of the entire image
*/


string GenerateDeepZoomMetadata(int tile_size,
                                int overlap,
                                string format,
                                int width,
                                int height)
{
  object XMLRoot = Parser.XML.Tree.RootNode();
  XMLRoot->add_child(
                     Parser.XML.Tree.Node(Parser.XML.Tree.XML_HEADER,
                                          "DOCTYPE",
                                          (["version":"1.0",
                                            "encoding":"utf-8"]),
                                          0));
  object ImageElement =  Parser.XML.Tree.Node(Parser.XML.Tree.XML_ELEMENT,
                                              "Image",
                                              (["Format":(string)format,
                                                "Overlap":(string)overlap,
                                                "TileSize":(string)tile_size,
                                                "xmlns":"http://schemas.microsoft.com/deepzoom/2008"]),
                                              0);
  object SizeElement =  Parser.XML.Tree.Node(Parser.XML.Tree.XML_ELEMENT,
                                             "Size",
                                             (["Height":(string)height,
                                               "Width":(string)width]),
                                             0);
  ImageElement->add_child(SizeElement);
  XMLRoot->add_child(ImageElement);
  
  return (XMLRoot->render_xml())+"\n"; // Seadragon needs a blank line after the XML;
}

/* Verify the metadata for a PNM file, and return the size */
array(int) GetPNMSize(string aFile)
{
  array(string) metadata = (Stdio.File(aFile)->read(2048)/"\n")[0..2];
  if (metadata[0]=="P6")
    return (array(int))(metadata[1]/" ");
  else
    throw (sprintf("%s does not appear to be a PNM file",
                   aFile));
}


/* Generate the temporary filename for a specific index */
string GetTemporaryFilename(string workspace,
                            int id)
{
  return Stdio.simplify_path(sprintf("%s/%d.pnm",
                                     workspace,
                                     id));
}

/* Load a region from a PNM file
   
   file: the PNM file from which to load the region
   offset: An array of int holding the starting offset in pixels
   size: An array of int holding the size to load
 */
Image.Image LoadPNMRegion(string file,
                          array(int) offset,
                          array(int) size)
{

  // Generate a basic PNM header for a given region size.
  // Used to decode a block of PNM data.
  string GeneratePNMMetadata(array(int) size)
  {
    return sprintf("P6\n%d %d\n255\n",
                   size[0], size[1]);
  };

  // Find the end of the header data in a PNM file
  int FindPNMHeaderEnd(string aFile)
  {
    string metadata = Stdio.File(aFile)->read(2048);
    int offset=1;
    for ( int x=0; x < 3; x++)
      offset = search(metadata,"\n",offset)+1;
    return offset;
  };

  array(int) imageSize = GetPNMSize(file);

  // Make local copies so we can modify them.
  array(int) local_offset = copy_value(offset);
  array(int) local_size = copy_value(size);

  // Restrict the region size to the bounds of the image
  array(int) margin = imageSize[*]-(local_offset[*]+local_size[*])[*];
  foreach ( ({0, 1}), int index )
    if (margin[index]<0)
      local_size[index] = imageSize[index] - local_offset[index];

  int lineStartOffset = local_offset[0];
  int lineEndOffset = imageSize[0]-(local_size[0]+local_offset[0]);

  // Extract the image data from the massive PNM file.
  String.Buffer buffer = String.Buffer();
  
  buffer->add(GeneratePNMMetadata(local_size));
  // Use an unbuffered file.
  Stdio.File input = Stdio.File(file);

  // Skip the header
  input->seek(FindPNMHeaderEnd(file));

  // Seek to the beginning of the block
  input->seek(input->tell()+ // Current position
              3*(local_offset[1]*imageSize[0])+ // Whole lines
              3*lineStartOffset); // Partial line

  // Read the block
  for (int x=0 ; x < local_size[1]; x++)
    {
      // Read the current line
      buffer->add(input->read(3*local_size[0]));
      // Skip to the next line
      input->seek(input->tell()+ // Current position
                  3*lineEndOffset+ // end of the line
                  3*lineStartOffset); // start of the next
    }

  // decode and return the image 
  return Image.PNM.decode(buffer->get());
}


/* Scale the input files for the image pyramid.
   Returns the number of layers created.

   Files are created in workspace, from the pnm source file
   in source.

   Limit is the size at which to stop producing the image pyramid.
   Zoomify format tiles stop the pyramid when it falls under
   the size of a single tile, but Deep Zoom format tilesets
   want to continue all the way down to a single pixel tile.
*/
int PrepareScaledInputFiles(string source, string workspace, int limit)
{
  // pnmscalefixed can be used in place of pamscale for a ~30%
  // speedup, with some minor quality loss, due to it not
  // supporting the filter option.
  string command_template = "pamscale 0.5 -filter sinc < %s  > %s";

  int counter = 0;

  // Link the initial input file as file 0
  System.symlink(source,
                 GetTemporaryFilename(workspace,counter));
  
  // Create new images until we are under the limit
  while (Array.any(GetPNMSize(GetTemporaryFilename(workspace,
                                                   counter)),
                   `>,
                   limit))
    Process.spawn(sprintf(command_template,
                          GetTemporaryFilename(workspace,
                                               counter),
                          GetTemporaryFilename(workspace,
                                               ++counter)))
      ->wait();
  return counter;
}

/* Cut tiles for a DeepZoom tileset.

   workspace: Path to a temporary workspace
   levels: number of levels in the image pyramid
   quality: JPEG quality level for output tiles
   output: Path to which output is written
   tilesize: Size of one side of the square tiles
*/
void CutDeepZoomTiles(string workspace,
                      int levels,
                      int quality,
                      string output,
		      int tilesize)
{
  mapping JPEG_OPTIONS = (["optimize":1,
                           "quality":quality,
                           "progressive":1]);
    

  for (int level = levels; level >=0 ; level --)
    {
      int step = levels-level;
      string current_path = Stdio.simplify_path(sprintf("%s/%s",
                                                        output,
                                                        (string)step));
      mkdir(current_path);
      
      array(int) imageSize = GetPNMSize(GetTemporaryFilename(workspace,
							     level));
      array(int) tiles = (array(int))(ceil((imageSize[*]/((float)tilesize))[*]));
      for (int x = 0 ; x < tiles[0] ; x++)
	for (int y = 0 ; y < tiles[1] ; y++)
	  Stdio.File(sprintf("%s/%d_%d.jpg",
			     current_path,
			     x, y),
		     "wct")->write(Image.JPEG.encode(LoadPNMRegion(GetTemporaryFilename(workspace,
											level),
								   ({tilesize*x, tilesize*y}),
								   ({tilesize,tilesize})),
						     JPEG_OPTIONS));
      // Clean up the tile data
      rm (GetTemporaryFilename(workspace,level));
    }
}


/*
  Generate a Seadragon deep zoom dataset (tiles and XML data)

  output: path at which the output is written
  name: name of the image
  workspace: path used as a temporary workspace
  levels: number of levels in the image pyramid
  quality: JPEG encoding quality for output tiles
 */
void DeepZoom(string output,
	      string name,
	      string workspace,
	      int levels,
	      int quality)
{

  string tileDir = sprintf("%s/%s_files",output,name);
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(sprintf("%s/0.pnm",workspace));

  Stdio.File(sprintf("%s/%s.dzi",
		     output,
		     name),
	     "wct")
    ->write(GenerateDeepZoomMetadata(256,0,"jpg",
				     imageSize[0],
				     imageSize[1]));
  CutDeepZoomTiles(workspace,
		   levels,
		   quality,
		   tileDir,
		   256);
}


int main(int argc, array(string) argv)
{
  
  if (getenv("TMP"))
    TEMP_DIR = getenv("TMP");
  else
    TEMP_DIR = "/var/tmp/";

  TEMP_DIR = Stdio.simplify_path(sprintf("%s/%s",
					 TEMP_DIR,
					 MIME.encode_base64(Crypto.Random.random_string(10))));

  if (argc !=4)
    {
      Stdio.stdout.write("Usage: tilecutter.pike <input> <outputdir> <outputname>\n");
    }
  else
    {
      mkdir(TEMP_DIR);
      DeepZoom(argv[2],
	       argv[3], TEMP_DIR,
	       PrepareScaledInputFiles(argv[1],
				       TEMP_DIR,
				       1),
	       65);
      rm(TEMP_DIR);
    }
}