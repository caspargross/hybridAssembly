#!/usr/bin/env/ nextflow

/* 
===============================================================================
   M I C R O B I A L   H Y B R I D   A S S E M B L Y   P I P E L I N E 
===============================================================================
ouextflow pipeline for hybrid assembly, quality check and plasmid finding
of bacterial genomes.
-------------------------------------------------------------------------------
@ Author
Caspar Groß <mail@caspar.one>
-------------------------------------------------------------------------------
@ Documentation
https://github.com/caspargross/hybridassembly/README.md
------------------------------------------------------------------------------
Processes overview:
... to be completed
------------------------------------------------------------------------------
*/


/* 
------------------------------------------------------------------------------
                       C O N F I G U R A T I O N 
------------------------------------------------------------------------------
*/
// Define valid run modes:
validModes = ['spades_simple', 'spades', 'spades_plasmid', 'canu', 'unicycler', 'flye', 'miniasm', 'all']

// Display version
if (params.version) exit 0, nextFlowMessage(), pipelineMessage()

// Check required input parameters
if (params.help) exit 0, helpMessage()
if (!params.mode) exit 0, helpMessage()
if (!params.input) exit 0, helpMessage()

// Set values from parameters:
sampleFile = file(params.input)
modes = params.mode.tokenize(',') 

// check if mode input is valid
if (!modes.every{validModes.contains(it)}) {
    exit 1,  log.info "Wrong execution mode, should be one of " + validModes
}

// assign Channel to inputFiles
files = extractFastq(sampleFile);

// Shorthands for conda environment activations
PY27 = "source activate ha_py27"
PY36 = "source activate ha_py36"

startMessage()

/* 
------------------------------------------------------------------------------
                           P R O C E S S E S 
------------------------------------------------------------------------------
*/

process seqpurge {
// Trim adapters on short read files
    tag{id}
    publishDir "${params.outDir}/${id}/01_qc_shortread/", mode: 'copy'
    
    input:
    set id, sr1, sr2, lr from files

    output:
    set id, file('sr1.fastq.gz'), file('sr2.fastq.gz'), lr into files_purged
    file("${id}_readQC.qcml")
    
    script:
    """
    $PY27  
    SeqPurge -in1 ${sr1} -in2 ${sr2} -threads ${params.cpu} -out1 sr1.fastq.gz -out2 sr2.fastq.gz -qc ${id}_readQC.qcml 
    """
}

process sample_shortreads {
// Subset short reads
    tag{id}

    input:
    set id, sr1, sr2, lr from files_purged

    output:
    set id, file('sr1_filt.fastq'), file('sr2_filt.fastq'), lr into files_filtered
    
    shell:
    '''
    !{PY27}
    readLength=$(zcat !{sr1} | awk 'NR % 4 == 2 {s += length($1); t++} END {print s/t}')
    srNumber=$(echo "(!{params.genomeSize} * !{params.targetShortReadCov})/${readLength}" | bc)
    seqtk sample -s100 !{sr1} ${srNumber} > sr1_filt.fastq 
    seqtk sample -s100 !{sr2} ${srNumber} > sr2_filt.fastq 
    '''
}

   
process porechop { 
// Trim adapter sequences on long read nanopore files
    tag{id}
        
    input:
    set id, sr1, sr2, lr from files_filtered
    
    output:
    set id, sr1, sr2, file('lr_porechop.fastq') into files_porechop
    set id, lr, val("raw") into files_nanoplot_raw
    
    script:
    // Join multiple longread files if possible 
    """
    $PY36
    cat ${lr} > nanoreads.fastq
    porechop -i nanoreads.fastq -t ${params.cpu} -o lr_porechop.fastq
    """
}


target_lr_length = params.targetLongReadCov * params.genomeSize
process filtlong {
// Quality filter long reads
    tag{id}

    input: 
    set id, sr1, sr2, lr from files_porechop
    
    output:
    set id, sr1, sr2, file("lr_filtlong.fastq") into files_pre_unicycler, files_pre_spades, files_pre_spades_plasmid, files_pre_canu, files_pre_miniasm, files_pre_flye
    set id, file("lr_filtlong.fastq"), val('filtered') into files_nanoplot_filtered
    
    script:
    """
    $PY36
    filtlong -1 ${sr1} -2 ${sr2} \
    --min_length 1000 \
    --keep_percent 90 \
    --target_bases  ${target_lr_length} \
    ${lr} > lr_filtlong.fastq
    """
}

process nanoplot {
// Quality check for nanopore reads and Quality/Length Plots
    tag{id}
    publishDir "${params.outDir}/${id}/01_qc_longread/${type}/", mode: 'copy'
    
    input:
    set id, lr, type from files_nanoplot_raw .mix(files_nanoplot_filtered)

    output:
    file '*.png'
    file '*.html'
    file '*.txt'
    
    script:
    """
    $PY36
    NanoPlot -t ${params.cpu} -p ${type}_  --title ${id}_${type} -c darkblue --fastq ${lr}
    """
}

/*process fastqc{
// Create FASTQC quality check on short reads
    tag{id}
    
    publishDir "${params.outDir}/${id}_${params.assembly}/fastQC/", mode: 'copy'

    input: 
    set id, sr1, sr2, lr from files_fastqc

    output:
    file "fastqc/\*"

    script: 
    """
    mkdir -p fastqc
    ${FASTQC} ${sr1} ${sr2} -o fastqc
    """
} */

process unicycler{
// complete bacterial hybrid assembly pipeline
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_unicycler", mode: 'copy'   
   
    input:
    set id, sr1, sr2, lr from files_pre_unicycler

    output:
    set id, sr1, sr2, lr, file("${id}/assembly.fasta"), val('unicycler') into assembly_unicycler
    file("${id}/*")

    when:
    isMode(['unicycler', 'all'])

    script:
    """ 
    $PY36
    unicycler -1 ${sr1} -2 ${sr2} -l ${lr} -o ${id} -t ${params.cpu}
    """
}

process spades{
// Spades Assembler running normal configuration
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_spades", mode: 'copy'   

    input:
    set id, sr1, sr2, longread from files_pre_spades  

    output:
    set id, sr1, sr2, longread, file("spades/contigs.fasta"), val('spades') into files_spades 
    set id, sr1, sr2, longread, file("spades/scaffolds.fasta"), val('spades_simple') into assembly_spades_simple 
    file("${id}_contigs_spades.fasta")
    set id, val('spades'), file("${id}_graph_spades.gfa") into assembly_graph
    file("${id}_scaffolds_spades.fasta")

    when:
    isMode(['spades','spades_simple','all'])
     
    script:
    """
    $PY36
    spades.py -t ${params.cpu} -m ${params.mem} \
    --phred-offset 33 --careful \
    --pe1-1 ${sr1} \
    --pe1-2 ${sr2} \
    --nanopore ${longread} \
    -o spades
    cp spades/assembly_graph_with_scaffolds.gfa ${id}_graph_spades.gfa
    cp spades/scaffolds.fasta ${id}_scaffolds_spades.fasta
    cp spades/contigs.fasta ${id}_contigs_spades.fasta
    """
}


process spades_plasmid{
// Spades Assembler running plasmid only configuration
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_spades_plasmid", mode: 'copy'   

    input:
    set id, sr1, sr2, lr from files_pre_spades_plasmid

    output:
    set id, sr1, sr2, lr, file("spades/scaffolds.fasta"), val('spades_plasmid') into files_spades_plasmid 
    file("${id}_contigs_spades_plasmid.fasta")
    set id, val('spades_plasmid'), file("${id}_graph_spades_plasmid.gfa") into assembly_graph
    file("${id}_scaffolds_spades_plasmid.fasta")

    when:
    isMode(['spades_plasmid','all'])
     
    script:
    """
    $PY36
    spades.py -t ${params.cpu} -m ${params.mem} \
    --phred-offset 33 --careful \
    --pe1-1 ${sr1} \
    --pe1-2 ${sr2} \
    --nanopore ${lr} \
    --plasmid \
    -o spades
    cp spades/assembly_graph_with_scaffolds.gfa ${id}_graph_spades_plasmid.gfa
    cp spades/scaffolds.fasta ${id}_scaffolds_spades_plasmid.fasta
    cp spades/contigs.fasta ${id}_contigs_spades_plasmid.fasta
    """
}

process links_scaffolding{
    // Scaffolding of assembled contigs using LINKS using long reads
    tag{id}
    publishDir "${params.outDir}/${id}/03_${type}_links", mode: 'copy'   
    
    input:
    set id, sr1, sr2, lr, scaffolds, type from files_spades .mix(files_spades_plasmid)
    
    output:
    set id, sr1, sr2, lr, file("${id}_${type}_scaffold_links.fasta"), type into files_links

    when:
    isMode(['spades', 'all'])
    
    script:
    """
    $PY36
    echo ${lr} > longreads.txt
    LINKS -x 1 -f ${scaffolds} -s longreads.txt -b links
    mv links.scaffolds.fa ${id}_${type}_scaffold_links.fasta
    """
}

process gapfiller{
   // Fill gaps in Scaffolds ('NNN') by finding matches in shortreads 
   tag{data_id}
   publishDir "${params.outDir}/${id}/03_gapfilling", mode: 'copy'   
   
   input:
   set id, sr1, sr2, lr, scaffolds, type from files_links
          
   output:
   set id, sr1, sr2, lr, file("${id}_gapfilled.fasta"), type into assembly_gapfiller

   script:
   """
   $PY27
   Gap2Seq -scaffolds ${scaffolds} -reads ${sr1},${sr2} -filled ${id}_gapfilled.fasta  -nf-cores ${params.cpu}
   """
}

process canu_parameters {
    // Create textfile with canu settings
    output: 
    file('canu_settings.txt') into canu_settings

    """
    echo \
    'genomeSize=$params.genomeSize 
    minReadLength=1000
    maxMemory=$params.mem 
    maxThreads=$params.cpu' > canu_settings.txt
    """
}

process canu{
    // Canu assembly tool for long reads
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_canu", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_canu
    file canu_settings
    
    output: 
    set id, sr1, sr2, lr, file("${id}.contigs.fasta"), val('canu') into files_unpolished_canu
    file("${id}.report")
    set id, val('canu'), file("${id}_graph_canu.gfa") into assembly_graph
    file("${id}_assembly_canu.fasta")

    when:
    isMode(['canu','all'])

    script:
    """
    $PY27
    canu -s ${canu_settings} -p ${id} -nanopore-raw ${lr}
    cp ${id}.unitigs.gfa ${id}_graph_canu.gfa
    cp ${id}.contigs.fasta ${id}_assembly_canu.fasta
    """
}

process miniasm{
    // Ultra fast long read assembly using minimap2 and  miniasm
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_miniasm", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_miniasm
    
    output:
    set id, sr1, sr2, lr, file("${id}_assembly_miniasm.fasta") into files_noconsensus
    set id, val('miniasm'), file("${id}_graph_miniasm.gfa") into assembly_graph

    when:
    isMode(['miniasm', 'all'])

    script:
    """
    $PY36
    minimap2 -x ava-ont -t ${params.cpu} ${lr} ${lr} > ovlp.paf
    miniasm -f ${lr} ovlp.paf > ${id}_graph_miniasm.gfa
    awk '/^S/{print ">"\$2"\\n"\$3}' ${id}_graph_miniasm.gfa | fold > ${id}_assembly_miniasm.fasta
    """
}

process racon {
    tag{id}
    // Improve result by realigning short reads to the miniasm assembly
    publishDir "${params.outDir}/${id}/03_racon", mode: 'copy'
    
    input:
    set id, sr1, sr2, lr, assembly from files_noconsensus

    output:
    set id, sr1, sr2, lr, file("${id}_consensus_racon.fasta"), val("miniasm") into files_unpolished_racon
    file("${id}_consensus_racon.fasta")

    script:
    """
    $PY36
    minimap2 -x map-ont -t ${params.cpu} ${assembly} ${lr} > assembly_map.paf
    racon -t ${params.cpu} ${lr} assembly_map.paf ${assembly} > ${id}_consensus_racon.fasta
    """
}

process flye {
// Assembly step using Flye assembler
    errorStrategy 'ignore'
    tag{id}
    publishDir "${params.outDir}/${id}/02_assembly_flye", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_flye

    output:
    set id, sr1, sr2, lr, file("flye/scaffolds.fasta"), val('flye') into files_unpolished_flye
    file("flye/assembly_info.txt")
    set id, val('flye') file("flye/${id}_graph_flye.gfa") into assembly_graph
    file("flye/${id}_assembly_flye.fasta")

    when:
    isMode(['flye', 'all'])

    script:
    """
    $PY27
    flye --nano-raw ${lr} --out-dir flye \
    --genome-size ${params.genomeSize} --threads ${params.cpu} -i 0
    cp flye/2-repeat/graph_final.gfa flye/${id}_graph_flye.gfa
    cp flye/scaffolds.fasta flye/${id}_assembly_flye.fasta
    """
}

// Create channel for all unpolished files to be cleaned with Pilon
files_unpolished = Channel.create()
files_pilon = files_unpolished.mix(files_unpolished_canu, files_unpolished_racon, files_unpolished_flye)

process pilon{
// Polishes long read assemly with short reads
    tag{id}
    publishDir "${params.outDir}/${id}/03_pilon", mode: 'copy'

    input:
    set id, sr1, sr2, lr, contigs, type from files_pilon

    output:
    set id, sr1, sr2, lr, file("${id}_${type}_pilon.fasta"), type into assembly_pilon

    script:
    """
    $PY36
    bowtie2-build ${contigs} contigs_index.bt2 

    bowtie2 --local --very-sensitive-local -I 0 -X 2000 -x contigs_index.bt2 \
    -1 ${sr1} -2 ${sr2} | samtools sort -o alignments.bam -T reads.tmp 
    
    samtools index alignments.bam

    pilon --genome ${contigs} --frags alignments.bam --changes \
    --output ${id}_${type}_pilon --fix all
    """
}

// Merge channel output from different assembly paths
assembly=Channel.create()
assembly_merged = assembly.mix(assembly_spades_simple, assembly_gapfiller, assembly_unicycler, assembly_pilon)

process draw_assembly_graph {
// Use Bandage to draw a picture of the assembly graph
    publishDir "${params.outDir}/${id}/04_assembled_genomes", mode: 'copy'

    input:
    set id, type, gfa from assembly_graph

    output:
    file("${id}_${type}_graph.svg")

    script:
    """
    $PY36
    Bandage image ${gfa} ${id}_${type}_graph.svg
    """
}


process format_final_output {
// Filter contigs by length and give consistenc contig naming
    publishDir "${params.outDir}/${id}/04_assembled_genomes", mode: 'copy'

    input:
    set id, sr1, sr2, lr, contigs, type from assembly_merged

    output:
    //set id, type into complete_status
    file("${id}_${type}_final_assembly.fasta")
    
    script:
    """
    $PY36
    format_output.py ${contigs} ${id} ${type} ${params.minContigLength}
    """

}


/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def helpMessage() {
  // Display help message
  // this.pipelineMessage()
  log.info "  Usage:"
  log.info "       nextflow run caspargross/hybridAssembly --input <file.csv> --mode <mode1,mode2...> [options] "
  log.info "    --input <file.tsv>"
  log.info "       TSV file containing paths to read files (id | shortread1| shortread2 | longread)"
  log.info "    --mode {${validModes}}"
  log.info "       Default: none, choose one or multiple modes to run the pipeline "
  log.info " "
  log.info "  Parameters: "
  log.info "    --outDir "
  log.info "    Output locattion (Default: current working directory"
  log.info "    --genomeSize <bases> (Default: 5300000)"
  log.info "    Expected genome size in bases."
  log.info "    --targetShortReadCov <coverage> (Default: 60)"
  log.info "    Short reads will be downsampled to a maximum of this coverage"
  log.info "    --targetLongReadCov <coverage> (Default: 60)"
  log.info "    Long reads will be downsampled to a maximum of this coverage"
  log.info "    --cpu <threads>"
  log.info "    set max number of threads per process"
  log.info "    --mem <Gb>"
  log.info "    set max amount of memory per process"
  log.info "    --minContigLength <length>"
  log.info "    filter final contigs for minimum length (Default: 1000)"
  log.info "          "
  log.info "  Options:"
//  log.info "    --shortRead"
//  log.info "      Uses only short reads. Only 'spades_simple', 'spades_plasmid' and 'unicycler' mode."
//  log.info "    --longRead"
//  log.info "      Uses long read only. Only 'unicycler', 'miniasm', 'canu' and 'flye'"
//  log.info "    --fast"
//  log.info "      Skips some steps to run faster. Only one cycle of error correction'" 
  log.info "    --version"
  log.info "      Displays pipeline version"
  log.info "           "
  log.info "  Profiles:"
  log.info "    -profile local "
  log.info "    Pipeline runs with locally installed conda environments (found in env/ folder)"
  log.info "    -profile test "
  log.info "    Runs complete pipeline on small included test dataset"
  log.info "    -profile localtest "
  log.info "    Runs test profile with locally installed conda environments"


}



def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line  : " + workflow.commandLine
  log.info "Profile       : " + workflow.profile
  log.info "Project Dir   : " + workflow.projectDir
  log.info "Launch Dir    : " + workflow.launchDir
  log.info "Work Dir      : " + workflow.workDir
  log.info "Cont Engine   : " + workflow.containerEngine
  log.info "Out Dir       : " + params.outDir
  log.info "Sample file   : " + sampleFile
  log.info "Expected size : " + params.genomeSize
  log.info "Target lr cov : " + params.targetLongReadCov
  log.info "Target sr civ : " + params.targetShortReadCov
  log.info "Containers    : " + workflow.container 
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def pipelineMessage() {
  // Display hybridAssembly info  message
  log.info "hybridAssembly Pipeline ~  version ${workflow.manifest.version} - revision " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def startMessage() {
  // Display start message
  // this.nextflowMessage()
  // this.asciiArt()
  this.minimalInformationMessage()
}

workflow.onComplete {
  // Display complete message
  // this.nextflowMessage()
  // this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

//workflow.onError {
  // Display error message
  //this.nextflowMessage()
  //log.info "Workflow execution stopped with the following message:"
  //log.info "  " + workflow.errorMessage
//}

def isMode(it) {
  // returns whether a given list of arguments contains at least one valid mode
it.any {modes.contains(it)}
}

def returnFile(it) {
// Return file if it exists
    if (workflow.profile in ['test', 'localtest'] ) {
        inputFile = file("$workflow.projectDir/" + it)
    } else {
        inputFile = file(it)
    }
    if (!file(inputFile).exists()) exit 1, "Missing file in TSV file: ${inputFile}, see --help for more information"
    return inputFile
}

def extractFastq(tsvFile) {
  // Extracts Read Files from TSV
  Channel.from(tsvFile)
  .ifEmpty {exit 1, log.info "Cannot find TSV file ${tsvFile}"}
  .splitCsv(sep:'\t', skip: 1)
  .map { row ->
    def id = row[0]
    def sr1 = returnFile(row[1])
    def sr2 = returnFile(row[2])
    def lr = returnFile(row[3])
    
    checkFileExtension(sr1, ".fastq.gz")
    checkFileExtension(sr2, ".fastq.gz")
    checkFileExtension(lr, ".fastq.gz")
   
    [id, sr1, sr2, lr]
    }
}

// Check file extension
  static def checkFileExtension(it, extension) {
    if (!it.toString().toLowerCase().endsWith(extension.toLowerCase())) exit 1, "File: ${it} has the wrong extension: ${extension} see --help for more information"
}
