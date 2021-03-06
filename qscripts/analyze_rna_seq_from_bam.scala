package org.broadinstitute.sting.queue.qscripts

import org.broadinstitute.sting.queue.QScript
import org.broadinstitute.sting.queue.util.QScriptUtils
import net.sf.samtools.SAMFileHeader.SortOrder
import org.broadinstitute.sting.utils.exceptions.UserException
import org.broadinstitute.sting.commandline.Hidden
import org.broadinstitute.sting.queue.extensions.picard.{ ReorderSam, SortSam, AddOrReplaceReadGroups, MarkDuplicates }
import org.broadinstitute.sting.queue.extensions.samtools._
import org.broadinstitute.sting.queue.extensions.gatk._

import org.broadinstitute.sting.queue.extensions.yeo._

class AnalyzeRNASeq extends QScript {
  // Script argunment
  @Input(doc = "input file or txt file of input files")
  var input: File = _

  @Argument(doc = "species (hg19...)")
  var species: String = _

  @Argument(doc = "STAR genome location")
  var star_genome_location: String = _

  @Argument(doc = "location of chr_sizes")
  var chr_sizes: String = _

  @Argument(doc = "adapter to trim")
  var adapter: List[String] = Nil

  @Argument(doc = "flipped", required = false)
  var flipped: String = _

  @Argument(doc = "not stranded", required = false)
  var not_stranded: Boolean = false

  @Argument(doc = "stringent run", required = false)
  var stringent: Boolean = false

  @Argument(doc = "location to place trackhub (must have the rest of the track hub made before starting script)")
  var location: String = "rna_seq"

  @Argument(doc = "annotation file to count tags on")
  var tags_annotation: String = _

  case class sortSam(inSam: File, outBam: File, sortOrderP: SortOrder) extends SortSam {
    override def shortDescription = "sortSam"
    this.input :+= inSam
    this.output = outBam
    this.sortOrder = sortOrderP
    this.createIndex = true
  }

  case class filterRepetitiveRegions(noAdapterFastq: File, filteredResults: File, filteredFastq: File) extends FilterRepetitiveRegions {
       override def shortDescription = "FilterRepetitiveRegions"

       this.inFastq = noAdapterFastq
       this.outCounts = filteredResults
       this.outNoRep = filteredFastq
       this.isIntermediate = true
  }

  case class genomeCoverageBed(input: File, outBed : File, cur_strand: String) extends GenomeCoverageBed {
        this.inBam = input
        this.genomeSize = chr_sizes
        this.bedGraph = outBed
        this.strand = cur_strand
        this.split = true
  }

  case class singleRPKM(input: File, output: File, s: String) extends SingleRPKM {
	this.inCount = input
	this.outRPKM = output
  }

  case class countTags(input: File, index: File, output: File, a: String) extends CountTags {
	this.inBam = input
	this.outCount = output
	this.tags_annotation = a
	if(not_stranded) {
	 this.flip = "both"
	} else {
	 this.flip = flipped
	}
  }

  case class star(input: File, output: File, stranded : Boolean, paired : File = null) extends STAR {
       this.inFastq = input

       if(paired != null) {
        this.inFastqPair = paired
       }

       this.outSam = output
       //intron motif should be used if the data is not stranded
       this.intronMotif = stranded
       this.genome = star_genome_location
  }

  case class addOrReplaceReadGroups(inBam : File, outBam : File) extends AddOrReplaceReadGroups {
       override def shortDescription = "AddOrReplaceReadGroups"
       this.input = List(inBam)
       this.output = outBam
       this.RGLB = "foo" //should record library id
       this.RGPL = "illumina"
       this.RGPU = "bar" //can record barcode information (once I get bardoding figured out)
       this.RGSM = "baz"
       this.RGCN = "Biogem" //need to add switch between biogem and singapore
       this.RGID = "foo"

  }

  case class samtoolsIndexFunction(input: File, output: File) extends SamtoolsIndexFunction {
       override def shortDescription = "indexBam"
       this.bamFile = input
       this.bamFileIndex = output
  }

  case class cutadapt(fastq_file: File, noAdapterFastq: File, adapterReport: File, adapter: List[String]) extends Cutadapt{
       override def shortDescription = "cutadapt"

       this.inFastq = fastq_file
       this.outFastq = noAdapterFastq
       this.report = adapterReport
       this.anywhere = adapter ++ List("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                                     "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT")
       this.overlap = 5
       this.length = 18
       this.quality_cutoff = 6
       this.isIntermediate = true
   }  

def stringentJobs(fastq_file: File) : File = {

        // run if stringent
      val noPolyAFastq = swapExt(fastq_file, ".fastq", ".polyATrim.fastq")
      val noPolyAReport = swapExt(noPolyAFastq, ".fastq", ".metrics")
      val noAdapterFastq = swapExt(noPolyAFastq, ".fastq", ".adapterTrim.fastq")
      val adapterReport = swapExt(noAdapterFastq, ".fastq", ".metrics")
      val filteredFastq = swapExt(noAdapterFastq, ".fastq", ".rmRep.fastq")
      val filtered_results = swapExt(filteredFastq, ".fastq", ".metrics")
            //filters out adapter reads
      add(cutadapt(fastq_file = fastq_file, noAdapterFastq = noAdapterFastq, 
          adapterReport = adapterReport, 
          adapter = adapter))
          
          
      add(filterRepetitiveRegions(noAdapterFastq, filtered_results, filteredFastq))
      add(new FastQC(filteredFastq))

      return filteredFastq
}
def script() {

    var stringent = false
    val fileList = QScriptUtils.createArgsFromFile(input)
    var trackHubFiles: List[File] = List()
    
    for (item : Tuple3[File, String, String] <- fileList) {
      var bamFile = item._1

      // run regardless of stringency
      val sortedBamFile = swapExt(bamFile, ".bam", ".sorted.bam")
      val rgSortedBamFile = swapExt(sortedBamFile, ".bam", ".rg.bam")
      val indexedBamFile = swapExt(rgSortedBamFile, "", ".bai")
      
      val NRFFile = swapExt(rgSortedBamFile, ".bam", ".NRF.metrics")

      val bedGraphFilePos = swapExt(rgSortedBamFile, ".bam", ".pos.bg")
      val bigWigFilePos = swapExt(bedGraphFilePos, ".bg", ".bw")

      val bedGraphFileNeg = swapExt(rgSortedBamFile, ".bam", ".neg.bg")
      val bedGraphFileNegInverted = swapExt(bedGraphFileNeg, "neg.bg", "neg.t.bg")
      val bigWigFileNeg = swapExt(bedGraphFileNegInverted, ".t.bg", ".bw")

      val countFile = swapExt(rgSortedBamFile, "bam", "count")
      val RPKMFile = swapExt(countFile, "count", "rpkm")

      //add bw files to list for printing out later
      trackHubFiles = trackHubFiles ++ List(bedGraphFileNegInverted, bigWigFilePos)
      add(new FastQC(inFastq = bamFile))
      add(new sortSam(bamFile, sortedBamFile, SortOrder.coordinate))
      add(addOrReplaceReadGroups(sortedBamFile, rgSortedBamFile))
      add(new samtoolsIndexFunction(rgSortedBamFile, indexedBamFile))
      add(new CalculateNRF(inBam = rgSortedBamFile, genomeSize = chr_sizes, outNRF = NRFFile))
      
      add(new genomeCoverageBed(input = rgSortedBamFile, outBed = bedGraphFilePos, cur_strand = "+"))
      add(new BedGraphToBigWig(bedGraphFilePos, chr_sizes, bigWigFilePos))

      add(new genomeCoverageBed(input = rgSortedBamFile, outBed = bedGraphFileNeg, cur_strand = "-"))
      add(new NegBedGraph(inBedGraph = bedGraphFileNeg, outBedGraph = bedGraphFileNegInverted))
      add(new BedGraphToBigWig(bedGraphFileNegInverted, chr_sizes, bigWigFileNeg))
	
      add(new countTags(input = rgSortedBamFile, index = indexedBamFile, output = countFile, a = tags_annotation))	
      add(new singleRPKM(input = countFile, output = RPKMFile, s = species))

    }
    add(new MakeTrackHub(trackHubFiles, location, species))
  }
}






