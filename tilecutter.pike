#! /usr/local/bin/pike

/* 
   Generate a basic set of XML data for a deep zoom image
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

array(int) GetPNMSize(string aFile)
{
  array(string) metadata = (Stdio.FILE(aFile)->read(2048)/"\n")[0..2];
  if (metadata[0]=="P6")
    return (array(int))(metadata[1]/" ");
  else
    throw (sprintf("%s does not appear to be a PNM file",
		   aFile));
}

string GenerateTemporaryFilename(string workspace,
				   int id)
{
  return Stdio.simplify_path(sprintf("%s/%d.pnm",
				      workspace,
				      id));
}



/* Scales the input files for the image pyramid.
   Returns the number of layers created.

   Files are created in workspace, from the pnm source file
   in source.
 */
int PrepareScaledInputFiles(string source, string workspace, int limit)
{

  string command_template = "pamscale 0.5 -filter sinc < %s  > %s";

  int counter = 0;
  System.symlink(source,
		 GenerateTemporaryFilename(workspace,0));
  
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

int main()
{
  PrepareScaledInputFiles("/Users/hungerf3/projects/zoom/pike/fs.pam",
			  "/Users/hungerf3/projects/zoom/pike/test",
			  1);
}