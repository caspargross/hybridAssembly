#!/usr/bin/env/ nextflow
params.assembly = ''

// Target coverage for long reads before assembly
target_sr_number = (params.target_shortread_cov * params.genome_size) / params.shortread_length
target_lr_length = params.target_longread_cov * params.genome_size

//inputFiles
files = Channel.fromPath(params.pathFile)
    .ifEmpty {error "Cannot find file with path locations in ${params.files}"}
    .splitCsv(header: true)
    .view()


// Validate assembly protocol choice:
if (!(params.assembly in ['spades_sspace', 'spades_links', 'canu', 'unicycler', 'flye', 'miniasm', 'all'])){
    exit 1, "Invalid assembly protocol: (${params.assembly}) \nMust be one of the following:\n    'canu'\n    'spades_links'\n    'spades_sspace'\n    'unicycler'\n    'miniasm'\n    'flye'\n    'all'"
}


// Trim adapters on short read files
process seqpurge {
    tag{id}
    
    input:
    set id, sr1, sr2, lr from files

    output:
    set id, file('sr1.fastq.gz'), file('sr2.fastq.gz'), lr into files_purged
    
    script:
    """
    $SEQPURGE -in1 ${sr1} -in2 ${sr2} -threads ${params.cpu} -out1 sr1.fastq.gz -out2 sr2.fastq.gz
    """


}

// Subset short reads
process sample_shortreads {
    tag{id}

    input:
    set id, sr1, sr2, lr from files_purged

    output:
    set id, file('sr1_filt.fastq'), file('sr2_filt.fastq'), lr into files_filtered
    
    script:
    """
    ${SEQTK} sample -s100 ${sr1} ${target_sr_number} > sr1_filt.fastq 
    ${SEQTK} sample -s100 ${sr2} ${target_sr_number} > sr2_filt.fastq 
    """



}

// Trim adapter sequences on long read nanopore files
process porechop {
    tag{id}
        
    input:
    set id, sr1, sr2, lr from files_filtered
    
    output:
    set id, sr1, sr2, file('lr_porechop.fastq') into files_porechop
    set id, lr, val("raw") into files_nanoplot_raw
    
    // Join multiple longread files if possible 
    script:
    """
    cat ${lr} > nanoreads.fastq
    $PORECHOP -i nanoreads.fastq -t ${params.cpu} -o lr_porechop.fastq
    """
}


// Quality filter long reads
process filtlong {
    tag{id}

    input: 
    set id, sr1, sr2, lr from files_porechop
    
    output:
    set id, sr1, sr2, file("lr_filtlong.fastq") into files_pre_unicycler, files_pre_spades, files_pre_canu, files_pre_miniasm, files_pre_flye,  files_fastqc
    set id, file("lr_filtlong.fastq"), val('filtered') into files_nanoplot_filtered
    
    
    
    script:
    """
    $FILTLONG -1 ${sr1} -2 ${sr2} \
    --min_length 1000 \
    --keep_percent 90 \
    --target_bases  ${target_lr_length} \
    ${lr} > lr_filtlong.fastq
    """
}

/*
*  NanoPlot 
*  plot read quality and read length distribution for ONT long reads
*  Creates summary files with read characteristics.
*/
process nanoplot {
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}/nanoplot/", mode: 'copy'
    
    input:
    set id, lr, type from files_nanoplot_raw .mix(files_nanoplot_filtered)

    output:
    file '*'
    
    script:
    """
    ${NANOPLOT} -t ${params.cpu} -p ${type}_  --title ${id}_${type} -c darkblue --fastq ${lr}
    """
}


// Create FASTQC quality check on short reads
process fastqc{
    tag{id}
    
    publishDir "${params.outFolder}/${id}_${params.assembly}/fastQC/", mode: 'copy'

    input: 
    set id, sr1, sr2, lr from files_fastqc

    output:
    file "fastqc/*"

    script: 
    """
    mkdir -p fastqc
    ${FASTQC} ${sr1} ${sr2} -o fastqc
    """
}

/*
* Unicycler - complete bacterial genome assembly pipeline
*
* 
*/
process unicycler{
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}/unicycler", mode: 'copy'   
   
    input:
    set id, sr1, sr2, lr from files_pre_unicycler

    output:
    set id, sr1, sr2, lr, file("${id}/assembly.fasta"), val('unicycler') into assembly_unicycler
    file("${id}/*")

    when:
    params.assembly in ['unicycler', 'all']

    script:
    """ 
    python3 /mnt/users/ahgrosc1/tools/Unicycler/unicycler-runner.py \
    -1 ${sr1} -2 ${sr2} -l ${lr}\
    -o ${id} -t ${params.cpu}\
    --spades_path ${SPADES}\
    --racon_path ${RACON}\
    --pilon_path ${PILON}\
    --bowtie2_build_path ${BOWTIE2_BUILD}\
    --bowtie2_path ${BOWTIE2}\
    --samtools_path ${SAMTOOLS}
    """
}

/*
* SPAades assembler
*
*
*/
process spades{
    tag{data_id}

    input:
    set data_id, forward, reverse, longread from files_pre_spades  

    output:
    set data_id, forward, reverse, longread, file("spades/scaffolds.fasta") into files_spades_sspace, files_spades_links
    file("spades/contigs.fasta")

    when:
    params.assembly in ['spades_sspace','spades_links','all']
    
    script:
    """
    ${SPADES} -t ${params.cpu} -m ${params.mem} \
    --phred-offset 33 --careful \
    --pe1-1 ${forward} \
    --pe1-2 ${reverse} \
    --nanopore ${longread} \
    -o spades
    """
}


/*
*  SSPACE scaffolder 
*
*
*/
process sspace_scaffolding{
    tag{data_id}

    input:
    set data_id, forward, reverse, longread, scaffolds from files_spades_sspace  

    output:
    set data_id, forward, reverse, longread, file("sspace/scaffolds.fasta"), val('spades_sspace') into files_sspace 
    
    when:
    params.assembly in ['spades_sspace','all']

    script:
    """
    perl ${SSPACE} -c ${scaffolds} -p ${longread} -b sspace -t ${params.cpu}
    """
}
    
/*
* Links scaffolder
*
*
*/
process links_scaffolding{
    tag{data_id}
    
    input:
    set data_id, forward, reverse, longread, scaffolds from files_spades_links
    
    output:
    set data_id, forward, reverse, longread, file("${data_id}_links.fasta"), val('spades_links') into files_links

    when:
    params.assembly in ['spades_links', 'all']
    
    script:
    """
    echo ${longread} > longreads.txt
    perl ${LINKS} -f ${scaffolds} -s longreads.txt -b links
    mv links.scaffolds.fa ${data_id}_links.fasta
    """
}

process gapfiller{
   tag{data_id}
   
   input:
   set data_id, forward, reverse, longread, scaffolds, type from files_sspace .mix(files_links)
          
   output:
   set data_id, forward, reverse, longread, file("${data_id}_gapfiller.fasta"), type into assembly_gapfiller

   script:
   """
   echo 'Lib1GF bowtie '${forward} ${reverse} '500 0.5 FR' > gapfill.lib
   perl ${GAPFILLER} -l gapfill.lib -s ${scaffolds} -m 32 -t 10 -o 2 -r 0.7 -d 200 -n 10 -i 15 -g 0 -T 5 -b out
   mv out/out.gapfilled.final.fa ${data_id}_gapfiller.fasta
   """
}

/*
*  Canu assembler
*
*
*/
process canu_parameters {

    output: 
    file('canu_settings.txt') into canu_settings

    """
    echo \
    'genomeSize=$params.genome_size 
    minReadLength=1000
    maxMemory=$params.mem 
    maxThreads=$params.cpu' > canu_settings.txt
    """
}

process canu{
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}/canu", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_canu
    file canu_settings
    
    output: 
    set id, sr1, sr2, lr, file("${id}.contigs.fasta"), val('canu') into files_unpolished_canu
    file("${id}.report")

    when:
    params.assembly in ['canu','all']

    script:
    """
    ${CANU} -s ${canu_settings} -p ${id} -nanopore-raw ${lr}
    """
}

/*
*  miniasm assembler
*
*
*/
process miniasm{
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}/miniasm", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_miniasm
    
    output:
    set id, sr1, sr2, lr, file("miniasm_assembly.fasta") into files_noconsensus

    when:
    params.assembly in ['miniasm', 'all']

    script:
    """
    ${MINIMAP2} -x ava-ont -t ${params.cpu} ${lr} ${lr} > ovlp.paf
    ${MINIASM} -f ${lr} ovlp.paf > miniasm_assembly.gfa
    awk '/^S/{print ">"\$2"\\n"\$3}' miniasm_assembly.gfa | fold > miniasm_assembly.fasta
    """
}

/*
* racon consensus tool
*
*
*/
process racon {
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}/racon", mode: 'copy'
    
    input:
    set id, sr1, sr2, lr, assembly from files_noconsensus

    output:
    set id, sr1, sr2, lr, file("assembly_consensus.fasta"), val("miniasm") into files_unpolished_racon
    file("assembly_consensus.fasta")

    script:
    """
    ${MINIMAP2} -x map-ont -t ${params.cpu} ${assembly} ${lr} > assembly_map.paf
    ${RACON} -t ${params.cpu} ${lr} assembly_map.paf ${assembly} assembly_consensus.fasta
    """
}

/* 
* Flye assembler (former ABruijn) 2018
*  
* De novo assembler for long and noisy reads. 
* Uses an A-Bruijnm graph to find overlaps in non-errorcorrected long reads
* Includes polisher module and repeat classification and analysis
*/
process flye {
    errorStrategy 'ignore'
    tag{id}
    publishDir "${params.outFolder}/${id}_${params.assembly}", mode: 'copy'

    input:
    set id, sr1, sr2, lr from files_pre_flye

    output:
    set id, sr1, sr2, lr, file("flye/scaffolds.fasta"), val('flye') into files_unpolished_flye
    file("flye/assembly_info.txt")
    file("flye/2-repeat/graph_final.gfa")

    
    when:
    params.assembly in ['flye', 'all']

    script:
    """
    ${FLYE} --nano-raw ${lr} --out-dir flye \
    --genome-size ${params.genome_size} --threads ${params.cpu} -i 0
    """
}

// Create channel for all unpolished files to be cleaned with Pilon
files_unpolished = Channel.create()
files_pilon = files_unpolished.mix(files_unpolished_canu, files_unpolished_racon, files_unpolished_flye)

/*
* Pilon polisher
*
*
*/
process pilon{
    tag{id}

    input:
    set id, sr1, sr2, lr, contigs, type from files_pilon

    output:
    set id, sr1, sr2, lr, file("after_polish.fasta"), type into assembly_pilon

    script:
    """
    ${BOWTIE2_BUILD} ${contigs} contigs_index.bt2 

    ${BOWTIE2} --local --very-sensitive-local -I 0 -X 2000 -x contigs_index.bt2 \
    -1 ${sr1} -2 ${sr2} | ${SAMTOOLS} sort -o alignments.bam -T reads.tmp 
    
    ${SAMTOOLS} index alignments.bam

    java -jar $PILON --genome ${contigs} --frags alignments.bam --changes \
    --output after_polish --fix all
    """
}

// Merge channel output from different assembly paths
assembly=Channel.create()
assembly_merged = assembly.mix(assembly_gapfiller, assembly_unicycler, assembly_pilon)

/*
* Length filter trimming of contigs < 2000bp from the final assembly
* Creates a plot of contig lenghts in the assembly
*/
process length_filter {
    publishDir "${params.outFolder}/${id}_${params.assembly}/", mode: 'copy'

    input:
    set id, sr1, sr2, lr, contigs, type from assembly_merged

    output:
    set id, file("${id}_${type}_final.fasta"), type into analysis_mummer, analysis_quast
    file("${id}_${type}_lengthDist.pdf")
    
    // Uses python2 
    script:
    """
    #!/usr/bin/env python

    import sys
    import os
    import numpy as np
    from Bio import SeqIO
    import pandas as pd
    import matplotlib
    matplotlib.use('Agg')
    from matplotlib import pyplot as plt

    long_contigs = []
    input_handle=open('${contigs}', 'rU')
    output_handle=open('${id}_${type}_final.fasta', 'w')
    
    for record in SeqIO.parse(input_handle, 'fasta'):
        if len(record.seq) >= 2000 :
            long_contigs.append(record)
    
    
    SeqIO.write(long_contigs, output_handle, "fasta")
    
    input_handle.close()
    output_handle.close()

    lengths = list(map(len, long_contigs))
    
    fig, ax = plt.subplots(figsize=(8, 3))
    ax.plot(lengths, np.repeat(1, len(lengths)),'bs')
    
    title = 'Contig lengths for ${id}'
    ax.set_title(title)
    ax.set_xscale('symlog')
    ax.set_xlabel("Nucleotides")
    ax.tick_params(
        axis = 'y',
        which = 'both',
        left = 'off',
        right = 'off',
        labelleft = 'off'
    )
    ax.xaxis.grid(False)
    fig.savefig("${id}_${type}_lengthDist.pdf", format='pdf')
    """

}

