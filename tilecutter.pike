#! /usr/local/bin/pike
/*  Tilecutter.pike
    Copyright 2011 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
    This program takes a PNM format image, and splits it into a set
    of tiles usable with "deep zoom" based viewers, such as Seadragon.

*/


/* 
   Generate a basic set of XML data for a deep zoom image.
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
						"Tilesize":(string)tile_size,
						"xmlns":"http://schemas.microsoft.com/deepzoom/2008"]),
					      0);
  object SizeElement =  Parser.XML.Tree.Node(Parser.XML.Tree.XML_ELEMENT,
					     "Size",
					     (["Height":(string)height,
					       "Width":(string)width]),
					     0);
  ImageElement->add_child(SizeElement);
  XMLRoot->add_child(ImageElement);
  
  return XMLRoot->render_xml();
}

/* Verify the metadata for a PNM file, and return the size */
array(int) GetPNMSize(string aFile)
{
  array(string) metadata = (Stdio.FILE(aFile)->read(2048)/"\n")[0..2];
  if (metadata[0]=="P6")
    return (array(int))(metadata[1]/" ");
  else
    throw (sprintf("%s does not appear to be a PNM file",
		   aFile));
}


/* Generate the temporary filename for a specific index */
string GenerateTemporaryFilename(string workspace,
				   int id)
{
  return Stdio.simplify_path(sprintf("%s/%d.pnm",
				      workspace,
				      id));
}

/* Load a region from a PNM file */
Image.Image LoadPNMRegion(string file,
			  array(int) offset,
			  array(int) size)
{

  // Generate a basic PNM header for a given region size.
  string GeneratePNMMetadata(array(int) size)
  {
    return sprintf("P6\n%d %d\n255\n",
		   size[0], size[1]);
  };

  int FindPNMHeaderEnd(string aFile)
  {
    string metadata = Stdio.FILE(aFile)->read(2048);
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
      local_size[index]+=margin[index];

  int lineStartOffset = local_offset[0];
  int lineEndOffset = imageSize[0]-(local_size[0]+local_offset[0]);

  // Extract the image data from the massive PNM file.
  string buffer = GeneratePNMMetadata(size);
  Stdio.FILE input = Stdio.FILE(file);

  // Skip the header
  input->seek(FindPNMHeaderEnd(file));

  // Seek to the beginning of the block
  input->seek(input->tell()+ // Current position
	      (local_offset[1]*imageSize[0])+ // Whole lines
	      lineStartOffset); // Partial line
  // Read the block
  for (int x=0 ; x < local_size[1]; x++)
    {
      // Read the current line
      buffer+=input->read(local_size[0]);
      // Skip to the next line
      input->seek(input->tell()+ // Current position
		  lineEndOffset+ // end of the line
		  lineStartOffset); // start of the next
    }

  // decode and return the image 
  return Image.PNM.decode(buffer);
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
		 GenerateTemporaryFilename(workspace,counter));
  
  while (Array.all(GetPNMSize(GenerateTemporaryFilename(workspace,
							counter)),
		   `>,
		   limit))
    Process.spawn(sprintf(command_template,
			   GenerateTemporaryFilename(workspace,
						     counter),
			   GenerateTemporaryFilename(workspace,
						     ++counter)))
      ->wait();
  return counter;
}

void CutDeepzoomTiles(string workspace,
		      int levels,
		      int quality,
		      string output)
{
  mapping JPEG_OPTIONS = (["optimize":1,
			   "quality":quality,
			   "progressive":1]);
    

  for (int level = levels; level >=0 ; level --)
    {
      int step = levels-level;
      string current_path = Stdio.simplify_path(sprintf("%s/%s",
							workspace,
							(string)step));
      mkdir(current_path);
      // Handle the simple case first. The entire level fits in one tile.
      if (Array.all(GetPNMSize(GenerateTemporaryFilename(workspace,
						       level)),
		    `<,
		    257))
	Stdio.FILE(current_path+"/0_0.jpg","wct")
	  ->write(Image.JPEG.encode(Image.PNM.decode(Stdio.FILE(GenerateTemporaryFilename(workspace,
											  level))
						     ->read()),
				    JPEG_OPTIONS));
      else
	{
	  array(int) imageSize = GetPNMSize(GenerateTemporaryFilename(workspace,
								      level));
	  

	}
	
    }

}



int main()
{
  //  PrepareScaledInputFiles("/Users/hungerf3/skip/new/out/merged.pnm",
  //			  "/Users/hungerf3/projects/zoom/pike/test",
  //			  1);

  
}