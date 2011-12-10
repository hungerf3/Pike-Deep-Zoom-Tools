#! /usr/local/bin/pike
/*  Tilecutter.pike
    Copyright 2011 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
    This program takes a PNM format image, and splits it into a set
    of tiles usable with "deep zoom" based viewers, such as Seadragon.
*/

// Defaults for command line flags
mapping FLAG_DEFAULTS = ([
  "format":"jpeg",
  "help":"False",
  "quality":"60",
  "type":"DeepZoom",
  "workspace": getenv("TMP") ? getenv("TMP") : "/var/tmp"
]);

// Acceptable values for command line flags
mapping FLAG_ACCEPTABLE_VALUES =([
  "type":(<"DeepZoom","Zoomify">),
  "format":(<"jpeg">)
]);

// Documentation for command line flags
mapping FLAG_HELP = ([
  "format": "Format to use for output tiles. Only jpeg is supported now.",
  "quality":"Quality to use for Jpeg encoding",
  "type":"Type of tile data to produce. DeepZoom or Zoomify.",
  "workspace":"Directory to use for temporary files.",
  "help":"Display help."
]);


/*
  Generate the XML data for a zoomify image

*/
string GenerateZoomifyMetadata(int tile_size,
			       int width,
			       int height,
			       int count)
{
  return sprintf("<IMAGE_PROPERTIES WIDTH=\"%d\" HEIGHT=\"%d\" NUMTILES=\"%d\" NUMIMAGES=\"1\" VERSION=\"1.8\" TILESIZE=\"%d\" />",
		 width,
		 height,
		 count,
		 tile_size);
}

/* 
   Generate theXML data for a seadragon deep zoom image.

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
  return combine_path(workspace,sprintf("%d.pnm",
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


/* Cut tiles for a Zoomify tileset.

   Returns the count of cut tiles.

   workspace: Path to a temporary workspace
   levels: number of levels in the image pyramid
   quality: JPEG quality level for output tiles
   output: Path to which output is written
   tileSize: Size of one side of the square tiles
*/
int CutZoomifyTiles(string workspace,
		    int levels,
		    int quality,
		    string output,
		    int tileSize)
{
  int count = 0;    // Total tiles cut
  int group = -1;    // Current tile group
  int inGroup = 0;  // Tiles in current group
  string currentPath; // Current working path.
  mapping JPEG_OPTIONS = (["optimize":1,
                           "quality":quality,
                           "progressive":1]);

  void UpdateCurrentPath()
  {
    group++;
    inGroup=0;
    currentPath = combine_path(output,sprintf("TileGroup%d",
					      group));
    mkdir(currentPath);
  };

  mkdir(output);
  UpdateCurrentPath();
  for (int level = levels; level >=0 ; level --)
    {
      string currentFile = GetTemporaryFilename(workspace,level);
      array(int) imageSize = GetPNMSize(currentFile);
      array(int) tiles = (array(int))(ceil((imageSize[*]/((float)tileSize))[*]));
      for (int x = 0 ; x < tiles[0] ; x++)
	for (int y = 0 ; y < tiles[1] ; y++)
	  {
	    if (inGroup >255) // Start a new group every 255 tiles
	      {
		UpdateCurrentPath();
		mkdir(currentPath);
	      }
	    Stdio.File(combine_path(currentPath,
				    sprintf("%d-%d-%d.jpg",
					    levels-level,
					    x,
					    y)),
		       "wct")->write(Image.JPEG.encode(LoadPNMRegion(currentFile,
								     ({tileSize*x,tileSize*y}),
								     ({tileSize,tileSize})),
						       JPEG_OPTIONS));
	    inGroup++;
	    count++;
	  }
      // Clean up the tile data
      rm(currentFile);
    }
  return count;
}


/* Cut tiles for a DeepZoom tileset.

   workspace: Path to a temporary workspace
   levels: number of levels in the image pyramid
   quality: JPEG quality level for output tiles
   output: Path to which output is written
   tileSize: Size of one side of the square tiles
*/
void CutDeepZoomTiles(string workspace,
                      int levels,
                      int quality,
                      string output,
		      int tileSize)
{
  mapping JPEG_OPTIONS = (["optimize":1,
                           "quality":quality,
                           "progressive":1]);
    

  for (int level = levels; level >=0 ; level --)
    {
      int step = levels-level;
      string currentFile = GetTemporaryFilename(workspace,
						level);
      string currentPath = combine_path(output,(string)step);
      mkdir(currentPath);
      
      array(int) imageSize = GetPNMSize(currentFile);
      array(int) tiles = (array(int))(ceil((imageSize[*]/((float)tileSize))[*]));
      for (int x = 0 ; x < tiles[0] ; x++)
	for (int y = 0 ; y < tiles[1] ; y++)
	  Stdio.File(combine_path(currentPath,sprintf("%d_%d.jpg",
						      x, y)),
		     "wct")->write(Image.JPEG.encode(LoadPNMRegion(currentFile,
								   ({tileSize*x, tileSize*y}),
								   ({tileSize,tileSize})),
						     JPEG_OPTIONS));
      // Clean up the tile data
      rm (currentFile);
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

  string tileDir = combine_path(output,sprintf("%s_files",name));
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(combine_path(workspace,"0.pnm"));

  Stdio.File(combine_path(output,
			  sprintf("%s.dzi",
				  name)),
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


/* Generate a zoomify dataset

   output: path at which the output is written
   name:  name of the image
   workspace: path used as a temporary workspace
   levels: number of levels in the image pyramid
   quality: JPEG encoding quality for output tiles
*/
void Zoomify(string output,
	     string name,
	     string workspace,
	     int levels,
	     int quality)
{

  string tileDir = combine_path(output,name);
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(combine_path(workspace,"0.pnm"));

  Stdio.File(combine_path(tileDir,"ImageProperties.xml"),
	     "wct")
    ->write(GenerateZoomifyMetadata(256,
				    imageSize[0],
				    imageSize[1],
				    CutZoomifyTiles(workspace,
						    levels,
						    quality,
						    tileDir,
						    256)));
						    
}


// check command lime flags
void check_flags(mapping FLAGS)
{
  foreach(indices(FLAGS), mixed aFlag)
    if (has_index(FLAG_ACCEPTABLE_VALUES,aFlag))
      if (!FLAG_ACCEPTABLE_VALUES[aFlag][FLAGS[aFlag]])
	{
	  Stdio.stderr.write(sprintf("Invalid value %s provided for %s.\n",
				     FLAGS[aFlag], aFlag));
	  FLAGS["help"]=1;
	}
}


// Display help 
void help()
{
  Stdio.stdout.write("Usage: tilecutter.pike [flags] <input> <outputdir> <outputname>\n");
  foreach(indices(FLAG_HELP), string aFlag)
    {
      Stdio.stdout.write(sprintf("--%s: %s (Default: %s)\n",
				 aFlag,
				 FLAG_HELP[aFlag],
				 FLAG_DEFAULTS[aFlag]));
    }
}


// Main
int main(int argc, array(string) argv)
{
  mapping FLAGS = FLAG_DEFAULTS|Arg.parse(argv);
  check_flags(FLAGS);

  if ( FLAGS["help"]==1 | sizeof(FLAGS[Arg.REST])!=3)
    {
      help();
      exit(1);
    }

  string INPUT = FLAGS[Arg.REST][0];
  string OUTPUT = FLAGS[Arg.REST][1];
  string NAME = FLAGS[Arg.REST][2];
  string WORKSPACE = combine_path(FLAGS["workspace"],
				  MIME.encode_base64(Crypto.Random.random_string(10)));
  mkdir(WORKSPACE);

  if (FLAGS["type"]=="DeepZoom")
    DeepZoom(OUTPUT,
	     NAME, WORKSPACE,
	     PrepareScaledInputFiles(INPUT,
				     WORKSPACE,
				     1),
	     (int)FLAGS["quality"]);
  else
    if (FLAGS["type"]=="Zoomify")
      Zoomify(OUTPUT,
	      NAME, WORKSPACE,
	      PrepareScaledInputFiles(INPUT,
				      WORKSPACE,
				      256),
	      (int)FLAGS["quality"]);
  rm(WORKSPACE);
}
