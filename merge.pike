#! /usr/local/bin/pike
/*  merge.pike
    Copyright 2011 by Jeff Hungerford <hungerf3@house.ofdoom.com>
    
    This program takes a set of overlapping TIFF images, and merges
    them into a single image.

    It won't do as good of a job as zoomify, and it uses the
    netpbm tools to do most of the work, but it should be
    usable as a workaround for composing large images until
    zoomify is usable again.
*/

string workspace;

// Defaults for command line flags
mapping FLAG_DEFAULTS = ([
  "help":"False",
  "output":"output.pnm",
  "workspace": getenv("TMP") ? getenv("TMP") : "/var/tmp"
]);

// Documentation for command line flags
mapping FLAG_HELP = ([
  "output":"Final output file.",
  "workspace":"Directory to use for temporary files.",
  "help":"Display help."
]);

void DecodeTiff(string file_name)
{
  Stdio.stderr.write(sprintf("Decoding %s\n",file_name));
  string command_template = "tifftopnm --alphaout=%s --byrow %s > %s";
  Process.spawn(sprintf(command_template,
			combine_path(workspace,"alpha.pgm"),
			file_name,
			combine_path(workspace,"data.pnm")))
    ->wait();
}

void AdjustMask(string input_mask,
		string image_mask,
		string output_mask)
{
  Stdio.stderr.write("Adjusting Image Mask\n");
  String.Buffer command = String.Buffer();
  // Smooth the outer 64 pixels of the mask
  command.add(sprintf("pnmsmooth --width=65 --height=65  %s ",
		      combine_path(workspace,input_mask)));
  command.add(" | ");
  // Clamp the mask outside of the origional boundries.
  command.add(sprintf("pamarith -min - %s",
		      combine_path(workspace,input_mask)));
  command.add(" | ");
  // Only apply the mask when over the already composed region.
  // image_mask marks the unused region; the inverse of
  //the occupied region.
  command.add(sprintf("pamarith -max - %s > %s",
		      combine_path(workspace,image_mask),
		      combine_path(workspace,output_mask)));

  Process.spawn(command.get())
    ->wait();
}

void UpdateImageMask(string image_mask,
		     string partial_mask)
{
  Stdio.stderr.write("updating Image Mask\n");
  String.Buffer command = String.Buffer();
  // invert the new mask
  command.add(sprintf("pnminvert %s",
		      combine_path(workspace,partial_mask)));
  command.add(" | ");
  // merge the masks
  command.add(sprintf("pamarith -min - %s",
		      combine_path(workspace,image_mask)));

  command.add(" | ");
  // Reduce to pgm
  command.add(sprintf("ppmtopgm > %s",
		      combine_path(workspace,"new-mask.pgm")));
  Process.spawn(command.get())
    ->wait();
  rm(combine_path(workspace,image_mask));
  mv(combine_path(workspace,"new-mask.pgm"),
     combine_path(workspace,image_mask));
}
	      
void BlendImage(string composite_image,
		string partial_image,
		string image_mask)
{
  Stdio.stderr.write("blending images\n");
  Process.spawn(sprintf("pamcomp -alpha=%s %s %s %s",
			combine_path(workspace,image_mask),
			combine_path(workspace,partial_image),
			combine_path(workspace,composite_image),
			combine_path(workspace,"new-composite-image.pam")))
    ->wait();
  rm(combine_path(workspace,composite_image));
  mv(combine_path(workspace,"new-composite-image.pam"),
     combine_path(workspace,composite_image));
}


// Display help 
void help()
{
  Stdio.stdout.write("Usage: merge.pike [flags] < filelist.txt \n");
  foreach(indices(FLAG_HELP), string aFlag)
    {
      Stdio.stdout.write(sprintf("--%s: %s (Default: %s)\n",
				 aFlag,
				 FLAG_HELP[aFlag],
				 FLAG_DEFAULTS[aFlag]));
    }
}




int main(int argc, array(string) argv)
{
  mapping FLAGS = FLAG_DEFAULTS|Arg.parse(argv);
  workspace =  combine_path(FLAGS["workspace"],
			    MIME.encode_base64(Crypto.Random.random_string(10)));

  if (FLAGS["help"]==1)
    {
      help();
      exit(1);
    }
  mkdir(workspace);
  int first_image=1;
  foreach(Stdio.stdin.line_iterator();; string aLine)
    {
      DecodeTiff(aLine);
      if(first_image) // Just move them into place
	{
	  first_image=0;
	  mv(combine_path(workspace,"data.pnm"),
	     combine_path(workspace,"image.pnm"));
	  mv(combine_path(workspace,"alpha.pgm"),
	     combine_path(workspace,"image-alpha.pgm"));
	}
      else
	{
	  AdjustMask("alpha.pgm",
		     "image-alpha.pgm",
		     "new-alpha.pgm");
	  rm(combine_path(workspace,"alpha.pgm"));
	  BlendImage("image.pnm",
		     "data.pnm",
		     "new-alpha.pgm");
	  UpdateImageMask("image-alpha.pgm",
			  "new-alpha.pgm");
	  foreach(({"new-alpha.pgm",
		    "data.pgm",
		    "alpha.pgm"}), string aFile)
	    rm(combine_path(workspace,aFile));
	}
    }
  mv(combine_path(workspace,"image.pnm"),
     FLAGS["output"]);
  foreach(({"image.pnm",
	    "image-alpha.pgm"}),
	  string aFile)
    rm(combine_path(workspace,aFile));
  rm(workspace);
}