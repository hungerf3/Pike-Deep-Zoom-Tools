#! /usr/local/bin/pike
/*  Tilecutter.pike
    Copyright 2011-2014 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
    This program takes a PNM format image, and splits it into a set
    of tiles usable with "deep zoom" based viewers, such as Seadragon.
*/


// Defaults for command line flags
mapping FLAG_DEFAULTS = ([
  "format":"jpeg",
  "help":0,
  "quality":60,
  "type":"DeepZoom",
  "workspace": getenv("TMP") ? getenv("TMP") : "/var/tmp",
  "verbose":0,
]);

// Acceptable values for command line flags
mapping FLAG_ACCEPTABLE_VALUES =([
  "type":(<"DeepZoom",
	   "SeaDragon",
	   "Zoomify"
  >),
  "format":(<"jpeg",
	     "png",
#if constant(Image.WebP)
	     "webp",
#endif
  >)
]);

// Documentation for command line flags
mapping FLAG_HELP = ([
  "format": "Format to use for output tiles.",
  "quality":"Quality to use for Jpeg encoding.",
  "type":"Type of tile data to produce",
  "workspace":"Directory to use for temporary files.",
  "help":"Display help.",
  "verbose":"Display more information.",
]);

mapping FLAGS = ([]);


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
   Generate the XML data for a seadragon deep zoom image.

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
  string command_template = "pamscale -xysize %d %d -filter sinc";
  String.Buffer command = String.Buffer();
  array(int) image_sizes;

  int counter = 0;

  array(int) next_level(array(int) image_sizes)
  {
    image_sizes = image_sizes[*]/2;
    image_sizes = max(image_sizes[*],1);
    return image_sizes;
  };

  int next_power_of_2(int x)
  {
    return pow(2,(int)Math.log2((float)x)+1);
  };

  // Get image sizes
  image_sizes = GetPNMSize(source);

  if (FLAGS["verbose"])
    Stdio.stderr.write(sprintf("Initial Image:  %d by %d\n",
			       image_sizes[0], image_sizes[1]));

  // Generate level 0 at the next higher power of 2.
  image_sizes[0] = next_power_of_2(image_sizes[0]);
  image_sizes[1] = next_power_of_2(image_sizes[1]);

  if (FLAGS["verbose"])
    Stdio.stderr.write(sprintf("Stage %d: %d by %d\n",
			       counter, image_sizes[0], image_sizes[1]));
  command.add(sprintf(command_template,
		      image_sizes[0],
		      image_sizes[1]));
  command.add(sprintf(" < %s ",
		      source));
  command.add(sprintf("| tee %s",
		      GetTemporaryFilename(workspace,
					   counter)));

  // Create new images until we are under the limit
  do
    {
      image_sizes = next_level(image_sizes);
      counter++;

      if (FLAGS["verbose"])
	Stdio.stderr.write(sprintf("Stage %d: %d by %d\n",
				   counter, image_sizes[0], image_sizes[1]));
      command.add(" | ");
      command.add(sprintf(command_template,
			  image_sizes[0],
			  image_sizes[1]));
      command.add(sprintf(" | tee %s ",
			  GetTemporaryFilename(workspace,
                                               counter)));
    }
  while (has_value(image_sizes[*]>limit,1));
  // while any of the image dimensions are greater than the limit

					   command.add(" > /dev/null "); // Empty the pipe
  // Run all of the resizes as a single pipeline
  // tapped at each output stage
  Process.spawn(command.get())
    ->wait();
      
  return counter++;
}


mapping get_encoders(mapping options)
{
  mapping encoders = ([
    "jpeg": lambda (Image.Image data)
	    {
	      return Image.JPEG.encode(data,
				       (["optimize":1,
					 "quality":options->quality,
					 "progressive":1]));
	    },
    "png": lambda (Image.Image data)
	   {
	     return Image.PNG.encode(data);
	   },
#if constant(Image.WebP)
    "webp": lambda (Image.Image data)
	    {
	      return Image.WebP.encode(data,
				       (["preset":Image.WebP.PRESET_PHOTO,
					 "quality":options->quality,
					 "autofilter":1]));
	    }
#endif
  ]);
  return encoders;
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
		    int tileSize,
		    string format)
{
  int count = 0;    // Total tiles cut
  int group = -1;    // Current tile group
  int inGroup = 0;  // Tiles in current group
  string currentPath; // Current working path.

  mapping encoders = get_encoders((["quality":quality]));

  mapping namePatterns = ([
    "jpeg": "%d-%d-%d.jpg",
    "png": "%d-%d-%d.png",
    "webp": "%d-%d-%d.webp"
  ]);
    
  void UpdateCurrentPath()
  {
    group++;
    inGroup=0;
    currentPath = combine_path(output,sprintf("TileGroup%d",
					      group));
    mkdir(currentPath);
  };

  function encoder = encoders[format];
  string namePattern = namePatterns[format];

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
				    sprintf(namePattern,
					    levels-level,
					    x,
					    y)),
		       "wct")->write(encoder(LoadPNMRegion(currentFile,
							   ({tileSize*x,tileSize*y}),
							   ({tileSize,tileSize}))));
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
		      int tileSize,
		      string format)
{
  mapping JPEG_OPTIONS = (["optimize":1,
                           "quality":quality,
                           "progressive":1]);

  mapping encoders =  get_encoders((["quality":quality]));

  mapping namePatterns = ([
    "jpeg": "%d_%d.jpg",
    "png": "%d_%d.png",
    "webp": "%d_%d.webp"
  ]);
  function encoder = encoders[format];
  string namePattern = namePatterns[format];


  for (int level = 0; level <= levels ; level ++)
    {
      string currentFile = GetTemporaryFilename(workspace,
						level);
      string currentPath = combine_path(output,(string)(levels-level));
      mkdir(currentPath);
      array(int) imageSize = GetPNMSize(currentFile);
      if (FLAGS["verbose"])
	Stdio.stderr.write(sprintf("Cutting Level %d; %d x %d\n",
				   level,
				   imageSize[0],
				   imageSize[1]));
      array(int) tiles = (array(int))(ceil((imageSize[*]/((float)tileSize))[*]));
      for (int x = 0 ; x < tiles[0] ; x++)
	for (int y = 0 ; y < tiles[1] ; y++)
	  Stdio.File(combine_path(currentPath,sprintf(namePattern,
						      x, y)),
		     "wct")->write(encoder(LoadPNMRegion(currentFile,
							 ({tileSize*x, tileSize*y}),
							 ({tileSize,tileSize}))));
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
	      int quality,
	      string format)
{
  mapping extensions = ([
    "jpeg": "jpg",
    "PNG": "png",
    "webp": "webp"
  ]);
  string tileDir = combine_path(output,sprintf("%s_files",name));
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(combine_path(workspace,"0.pnm"));

  Stdio.File(combine_path(output,
			  sprintf("%s.dzi",
				  name)),
	     "wct")
    ->write(GenerateDeepZoomMetadata(256,0,extensions[format],
				     imageSize[0],
				     imageSize[1]));
  CutDeepZoomTiles(workspace,
		   levels,
		   quality,
		   tileDir,
		   256,
		   format);
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
	     int quality,
	     string format)
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
						    256,
						    "jpeg")));
						    
}


// check command lime flags
void check_flags(mapping FLAGS)
{
  // Preflight
  if (FLAGS["type"] == "Zoomify")
    {
      FLAG_ACCEPTABLE_VALUES["format"]=(<"jpeg">);
    }

  foreach(indices(FLAGS), mixed aFlag)
    if (has_index(FLAG_ACCEPTABLE_VALUES,aFlag))
      if (!FLAG_ACCEPTABLE_VALUES[aFlag][FLAGS[aFlag]])
	{
	  Stdio.stderr.write(sprintf("Invalid value %s provided for %s.\nAcceptable values are: %s\n",
				     FLAGS[aFlag], aFlag,
				     (indices(FLAG_ACCEPTABLE_VALUES[aFlag])*", ")));
	  FLAGS["help"]=1;
	}
}

// Display help 
void help()
{
  Stdio.stdout.write("Usage: tilecutter.pike [flags] <input> <outputdir> <outputname>\n");
  foreach(indices(FLAG_HELP), string aFlag)
    {
      string acceptable_flags = "";
      if (FLAG_ACCEPTABLE_VALUES[aFlag])
	acceptable_flags = sprintf("(Acceptable: %s )",indices(FLAG_ACCEPTABLE_VALUES[aFlag])*", ");

      Stdio.stdout.write(sprintf("--%s: %s (Default: %s) %s\n",
				 aFlag,
				 FLAG_HELP[aFlag],
				 (string)FLAG_DEFAULTS[aFlag],
				 acceptable_flags));
    }
}


// Main
int main(int argc, array(string) argv)
{
  FLAGS = FLAG_DEFAULTS|Arg.parse(argv);
  check_flags(FLAGS);

  if ( FLAGS["help"]==1 | sizeof(FLAGS[Arg.REST])!=3)
    {
      help();
      exit(1);
    }

  string INPUT = combine_path(getcwd(),
			      FLAGS[Arg.REST][0]);
  string OUTPUT = combine_path(getcwd(),
			       FLAGS[Arg.REST][1]);
  string NAME = FLAGS[Arg.REST][2];
  string WORKSPACE = combine_path(getcwd(),
				  FLAGS["workspace"],
				  String.string2hex(Crypto.Random.random_string(10)));
  mkdir(WORKSPACE);

  if ((<"DeepZoom","SeaDragon">)[FLAGS["type"]])
    DeepZoom(OUTPUT,
	     NAME, WORKSPACE,
	     PrepareScaledInputFiles(INPUT,
				     WORKSPACE,
				     1),
	     (int)FLAGS["quality"],
	     FLAGS["format"]);
  if ((<"Zoomify">)[FLAGS["type"]])
    Zoomify(OUTPUT,
	    NAME, WORKSPACE,
	    PrepareScaledInputFiles(INPUT,
				    WORKSPACE,
				    256),
	    (int)FLAGS["quality"],
	    "jpeg");
  rm(WORKSPACE);
}
