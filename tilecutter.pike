#!/usr/local/bin/pike
/*  Tilecutter.pike
    Copyright 2011-2023 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
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
  "tilesize": 256
]);

// Acceptable values for command line flags
mapping FLAG_ACCEPTABLE_VALUES =([
  "type":(<"DeepZoom",
	   "SeaDragon",
	   "Zoomify",
     "Pannellum"
  >),
  "format":(<"jpeg",
	     "png",
       "pnm",
#if constant(Image.WebP)
	     "webp",
#endif
  >)
]);

// Documentation for command line flags
mapping FLAG_HELP = ([
  "format": "Format to use for output tiles.",
  "quality":"Quality to use for Jpeg / webp encoding.",
  "type":"Type of tile data to produce",
  "workspace":"Directory to use for temporary files.",
  "help":"Display help.",
  "verbose":"Display more information.",
  "tilesize":"Maximum size of each tile."
]);

mapping TYPE_HELP = ([
  "Pannellum": "Input is a comma seperated list of (possibly null) cube face PNM files. Front,right,back,left,up,down.",
  "Zoomify": "This is an old format, and only supports JPEG files."
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


/* Read the header from a PNM file, and return the size */
array(int) GetPNMSize(string aFile)
{
   return GetSizeFromHeader(GetPNMHeader(aFile));
}

/* Get and verify the header from a PNM */
array(string) GetPNMHeader(string aFile)
{
  array(string) metadata = (Stdio.File(aFile)->read(2048)/"\n")[0..2];
  if ((<"P5", "P6">)[metadata[0]])
    return metadata;
    else
      throw (sprintf("%s does not appear to be a Color or Grayscale PNM file",
                     aFile));
}

/* Return the size from a PNM header */
array(int) GetSizeFromHeader(array(string) metadata)
{
  return (array(int))(metadata[1]/" ");
}

/* Get the maximum color value from a PNM header*/
int getMaxvalFromHeader(array(string) metadata)
{
  return (int)(metadata[2]);
}

/* Get the version from a PNM header*/
int getVersionFromHeader(array(string) metadata)
{
  return (int)(metadata[0][1..]);
}

/* Get the BPP count for a PNM Header*/
int GetBPPFromHeader(array(string) metadata)
{
  int bytes = (["P5": 1,
                "P6": 3])[metadata[0]];
  if (getMaxvalFromHeader(metadata)> 255)
    bytes = bytes * 2;
  return bytes;
}


/* Generate the temporary filename for a specific index */
string GetTemporaryFilename(string workspace,
                            int id)
{
  return combine_path(workspace,sprintf("%d.pnm",
					id));
}


/* Load a region from a PNM file

  Returns a string containing PNM data for the region.
   
   file: the PNM file from which to load the region
   offset: An array of int holding the starting offset in pixels
   size: An array of int holding the size to load
 */
string LoadPNMRegion(string file,
                          array(int) offset,
                          array(int) size)
{

  // Generate a basic PNM header for a given region size.
  // Used to decode a block of PNM data.
  string GeneratePNMMetadata(array(int) size, int version, int maxval)
  {
    return sprintf("P%d\n%d %d\n%d\n",
                   version, size[0], size[1], maxval);
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
  array(string) header = GetPNMHeader(file);
  array(int) imageSize = GetSizeFromHeader(header);
  int imageMaxval = getMaxvalFromHeader(header);
  int imageSamples = GetBPPFromHeader(header);
  int imageVersion = getVersionFromHeader(header);

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
  
  buffer->add(GeneratePNMMetadata(local_size,
                                  imageVersion,
                                  imageMaxval));
  // Use an unbuffered file.
  Stdio.File input = Stdio.File(file);

  // Skip the header
  input->seek(FindPNMHeaderEnd(file));

  // Seek to the beginning of the block
  input->seek(input->tell()+ // Current position
              imageSamples*(local_offset[1]*imageSize[0])+ // Whole lines
              imageSamples*lineStartOffset); // Partial line

  // Read the block
  for (int x=0 ; x < local_size[1]; x++)
    {
      // Read the current line
      buffer->add(input->read(imageSamples*local_size[0]));
      // Skip to the next line
      input->seek(input->tell()+ // Current position
                  imageSamples*lineEndOffset+ // end of the line
                  imageSamples*lineStartOffset); // start of the next
    }

  
  return buffer->get();
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
    "jpeg": lambda (string data)
	    {
	      return Image.JPEG.encode(Image.PNM.decode(data),
				       (["optimize":1,
					      "quality":options->quality,
					      "progressive":1]));
	    },
    "png": lambda (string data)
	   {
	     return Image.PNG.encode(Image.PNM.decode(data));
	   },
     "pnm": lambda (string data)
     {
        return data;
     },
#if constant(Image.WebP)
    "webp": lambda (string data)
	    {
	      return Image.WebP.encode(Image.PNM.decode(data),
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
   quality: encoding quality level for output tiles (for JPEG)
   output: Path to which output is written
   tileSize: Size of one side of the square tiles
   format: Format to use when writing tiles
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
    
  void UpdateCurrentPath()
  {
    group++;
    inGroup=0;
    currentPath = combine_path(output,sprintf("TileGroup%d",
					      group));
    mkdir(currentPath);
  };

 mapping extensions = ([
    "jpeg": "jpg",
    "PNG": "png",
    "webp": "webp",
    "pnm": "pnm"
  ]);

  function encoder = encoders[format];
  string namePattern = "%d-%d-%d." + extensions[format];

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
   quality: encoding quality level for output tiles (for JPEG)
   output: Path to which output is written
   tileSize: Size of one side of the square tiles
   format: Format to use when writing tiles
   pattern: Optional naming pattern to use for tiles
   base: Optional lowest value for a tile set
   orient: Optional 0=ltr 1=ttb
   
*/
void CutDeepZoomTiles(string workspace,
                      int levels,
                      int quality,
                      string output,
		                  int tileSize,
		                  string format,
                      string|void pattern,
                      int|void base,
                      int|void orient)
{
  mapping encoders =  get_encoders((["quality":quality]));

 mapping extensions = ([
    "jpeg": "jpg",
    "PNG": "png",
    "webp": "webp",
    "pnm": "pnm"
  ]);

  function encoder = encoders[format];
  string namePattern = "%d_%d";
  int theBase = 0;
  int theOrientation = 0;

  if (!zero_type(orient))
    theOrientation = orient;
  
  if (!zero_type(base))
    theBase = base;

  if (!zero_type(pattern))
  {
    namePattern = pattern;
  }
   namePattern = namePattern + "." + extensions[format];

  for (int level = 0; level <= levels ; level ++)
    {
      string currentFile = GetTemporaryFilename(workspace,
						level);
      string currentPath = combine_path(output,(string)(levels-level+theBase));
      mkdir(currentPath);
      array(int) imageSize = GetPNMSize(currentFile);
      if (FLAGS["verbose"])
	Stdio.stderr.write(sprintf("Cutting Level %d; %d x %d\n",
				   level,
				   imageSize[0],
				   imageSize[1]));
      int xi;
      int yi;
      array(int) tiles = (array(int))(ceil((imageSize[*]/((float)tileSize))[*]));
      for (int x = 0 ; x < tiles[0] ; x++)
	for (int y = 0 ; y < tiles[1] ; y++)
  {
    if (theOrientation == 1)
    {
      xi=y; yi=x;
    }
    else
    {
      xi=x; yi=y;
    }
	  Stdio.File(combine_path(currentPath,sprintf(namePattern,
						      xi, yi)),
		     "wct")->write(encoder(LoadPNMRegion(currentFile,
							 ({tileSize*x, tileSize*y}),
							 ({tileSize,tileSize}))));
  }
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
  quality: encoding quality for output tiles (for JPEG)
  format: Format to use when writing tiles
 */
void DeepZoom(string output,
	      string name,
	      string workspace,
	      int levels,
	      int quality,
	      string format,
        int tileSize)
{
  mapping extensions = ([
    "jpeg": "jpg",
    "PNG": "png",
    "webp": "webp",
    "pnm": "pnm"
  ]);
  string tileDir = combine_path(output,sprintf("%s_files",name));
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(combine_path(workspace,"0.pnm"));

  Stdio.File(combine_path(output,
			  sprintf("%s.dzi",
				  name)),
	     "wct")
    ->write(GenerateDeepZoomMetadata(tileSize,0,extensions[format],
				     imageSize[0],
				     imageSize[1]));
  CutDeepZoomTiles(workspace,
		   levels,
		   quality,
		   tileDir,
		   tileSize,
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
	     string format,
       int tileSize)
{

  string tileDir = combine_path(output,name);
  mkdir(tileDir);

  array(int) imageSize = GetPNMSize(combine_path(workspace,"0.pnm"));

  Stdio.File(combine_path(tileDir,"ImageProperties.xml"),
	     "wct")
    ->write(GenerateZoomifyMetadata(tileSize,
				    imageSize[0],
				    imageSize[1],
				    CutZoomifyTiles(workspace,
						    levels,
						    quality,
						    tileDir,
						    tileSize,
						    "jpeg")));
						    
}

/*
  Prepare a Pannellum cubic multi resolution tile set.

  This is is more complex than other formats, as we need to generate
  tile sets for each cube face.

*/

string GeneratePanellumMetadata(int tileSize,
                                int cubeSize,
                                int levels,
                                string format)
{
  return Standards.JSON.encode (([   "type": "multires",
    "autoLoad": Val.True(),
    "multiRes": ([
      "path": "%l/%s%y_%x",
      "fallbackPath": "fallback/%s",
      "extension": format,
      "maxLevel": levels,
      "cubeResolution": cubeSize,
      "tileResolution": tileSize
    ])
  ]),
  Standards.JSON.HUMAN_READABLE |
  Standards.JSON.PIKE_CANONICAL);
}


void Pannellum(string output,
               string name,
               string workspace,
               string format,
               int quality,
               int tilesize,
               string input)
{
  string namePattern = "%d_%d";
  // Match the face order from Erect2cubic
  array(string) directions = ({"f", "r", "b", "l", "u", "d"});
  array(string) inputs;

    mapping extensions = ([
    "jpeg": "jpg",
    "PNG": "png",
    "webp": "webp",
    "pnm": "pnm"
  ]);

  if (!has_value(input, ","))
  {
    Stdio.stderr.write("Currently Panellum format requires a set of cube faces, rather than a single image.");
    return;
  }

  inputs = input/",";
  if (sizeof(inputs)!=6)
  {
    Stdio.stderr.write("Panellum format requres 6 cube faces, seperated by commas");
  }

  string tileDir = combine_path(output,name);
  mkdir(tileDir);
  mkdir(combine_path(tileDir,"fallback"));

  int current_direction = 0;
  int face_size;
  int levels;
  foreach(inputs, string anInput)
  {
    if (sizeof(anInput)!=0)
    {
      // Start the generation of the fallback image for this cube face
      object fallbackGenerator = Process.spawn("pamscale -filter sinc -xysize" + 
                                               sprintf(" %d %d ", tilesize*2, tilesize*2)+
                                               " < " + combine_path(getcwd(), anInput) + 
                                               " > " + combine_path(workspace, "fallback.pnm"));

      // Generate the scaled images
      levels = PrepareScaledInputFiles(combine_path(getcwd(),anInput),
                                           workspace,
                                           tilesize);
      face_size = GetPNMSize(combine_path(workspace,"0.pnm"))[0];
      CutDeepZoomTiles(workspace,
                      levels,
                      quality,
                      tileDir,
                      tilesize,
                      format,
                      directions[current_direction]+namePattern,
                      1, 1);
      // Convert the fallback image to the required format
      fallbackGenerator->wait(); // make sure the fallback image has generated
      Stdio.File(combine_path(tileDir,
                              "fallback",
                              directions[current_direction]+"."+extensions[format]),
                  "wct")->write(get_encoders(([
                                  "quality":quality
                                  ]))[format](Stdio.File(combine_path(workspace,
                                                                      "fallback.pnm"))->read()));
      rm(combine_path(workspace,"fallback.pnm"));
    }
    current_direction++;
  }
  // generate the metadata for the tile set
  Stdio.File(combine_path(tileDir,
                          "config.json"),
            "wct")->write(GeneratePanellumMetadata(tilesize,
                                                   face_size,
                                                   levels+1,
                                                   extensions[format]));
}

// check command lime flags
void check_flags(mapping FLAGS)
{
  // Preflight
  // Check for all needed fields
  if (sizeof(FLAGS[Arg.REST])!=3)
  {
    FLAGS["help"]=1;
    return;
  }

  if (FLAGS["type"] == "Zoomify")
    {  // Zoomify is an old format, and only supports jpeg
      FLAG_ACCEPTABLE_VALUES["format"]=(<"jpeg">);
    }

  if (((int)(FLAGS["tilesize"])) < 1)
  { 
    Stdio.stderr.write(sprintf("Invalid value %s provided for %s.\nAcceptable values are: %s\n",
				                        FLAGS["tilesize"], "tilesize",
                                "greater than zero"));
    FLAGS["help"]=1;
    return;
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
  Stdio.stdout.write("Flag Help:\n");
  foreach(sort(indices(FLAG_HELP)), string aFlag)
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
Stdio.stdout.write("Tile Type Notes:\n");
foreach(sort(indices(TYPE_HELP)), string aType)
{
  Stdio.stdout.write(sprintf("%s: %s\n", aType, TYPE_HELP[aType]));
}
}


// Main 
int main(int argc, array(string) argv)
{
  FLAGS = FLAG_DEFAULTS|Arg.parse(argv);
  check_flags(FLAGS);

  if ( FLAGS["help"]==1)
    {
      help();
      exit(1);
    }

  string INPUT = combine_path(getcwd(),
			      FLAGS[Arg.REST][0]);
  string OUTPUT = combine_path(getcwd(),
			       FLAGS[Arg.REST][1]);
  string NAME = FLAGS[Arg.REST][2];
  int    tileSize = (int)(FLAGS["tilesize"]);
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
	     FLAGS["format"],
       tileSize);
  if ((<"Zoomify">)[FLAGS["type"]])
    Zoomify(OUTPUT,
	    NAME, WORKSPACE,
	    PrepareScaledInputFiles(INPUT,
				    WORKSPACE,
				    tileSize),
	    (int)FLAGS["quality"],
	    "jpeg",
      tileSize);
  if ((<"Pannellum">)[FLAGS["type"]])
    Pannellum(OUTPUT,
              NAME,
              WORKSPACE,
              FLAGS["format"],
              (int)(FLAGS["quality"]),
              tileSize,
              INPUT);
  rm(WORKSPACE);
}
