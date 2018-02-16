#!/usr/bin/env/ nextflow
params.assembly = 'spades_sspace'
params.return_all = false 

/* Pipeline paths:

spades_sspace
spades_links
canu-pilon
miniasm

*/



//inputFiles
files = Channel.fromPath(params.pathFile)
    .ifEmpty {error "Cannot find file with path locations in ${params.files}"}\
    .splitCsv(header: true)
    .view()

// Multiply input file channel
files.into{files1; files2; files3; files4; files5}


// Create quality control plots for longreads
/*
TODO
process nanoplot {
    tag{id}
}
*/


// Trim adapter sequences on long read nanopore files
process porechop {
    tag{id}
        
    input:
    set id, sr1, sr2, lr from files1
    
    output:
    set id, sr1, sr2, file('lr_porechop.fastq') into files_porechop
    
    script:
    """
    $PORECHOP -i ${lr} -t ${params.cpu} -o lr_porechop.fastq
    """
}

// Quality filter long reads
process filtlong {
    tag{id}

    input: 
    set id, sr1, sr2, lr from files_porechop
    
    output:
    set id, sr1, sr2, file("lr_filtlong.fastq") into files_filtlong
    
    script:
    """
    $FILTLONG -1 ${sr1} -2 ${sr2} \
    --min_length 1000 \
    --keep_percent 90 \
    --target_bases  100000000 \
    ${lr} > lr_filtlong.fastq
    """
    // Expected genome size: 5.3Mbp --> Limit to 100Mbp for approx 20x coverage
}


if (params.assembly == "spades_sspace" || params.assembly == "spades_links") {
    
    // Run SPADes assembly
    process spades{
        tag{data_id}

        // Write spades output to folder
        publishDir "${params.outFolder}/${data_id}/spades", mode: 'copy'

        input:
        set data_id, forward, reverse, longread from files_filtlong  

        output:
        set data_id, forward, reverse, longread, file("spades/scaffolds.fasta") into files_spades
        file("spades/contigs.fasta")

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
}



// Scaffold using SSPACE
if(params.assembly == 'spades_sspace'){

    process sspace_scaffolding{
        tag{data_id}

        input:
        set data_id, forward, reverse, longread, scaffolds from files_spades  

        output:
        set data_id, forward, reverse, longread, file("sspace/scaffolds.fasta") into files_sspace 

        script:
        """
        perl ${SSPACE} -c ${scaffolds} -p ${longread} -b sspace -t ${params.cpu}
        """
    }
    
    process gapfiller{
       tag{data_id}
       
       if (params.return_all) {
           publishDir "${params.outFolder}/${data_id}/gapfiller", mode: 'copy' 
       }

       input:
       set data_id, forward, reverse, longread, scaffolds from files_sspace
              
       output:
       set data_id, forward, reverse, longread, file("${data_id}_gapfiller.fasta") into files_assembled

       script:
       """
       echo 'Lib1GF bowtie '${forward} ${reverse} '500 0.5 FR' > gapfill.lib
       perl ${GAPFILLER} -l gapfill.lib -s ${scaffolds} -m 32 -t 10 -o 2 -r 0.7 -d 200 -n 10 -i 15 -g 0 -T 5 -b out
       mv out/out.gapfilled.final.fa ${data_id}_gapfiller.fasta
       """
    }
}

if(params.assembly == 'spades_links'){
    process links_scaffolding{
        tag{data_id}
        
        if (params.return_all) {
            publishDir "${params.outFolder}/${data_id}/links/", mode: 'copy'
        }

        input:
        set data_id, forward, reverse, longread, scaffolds from files_spades
        
        output:
        set data_id, forward, reverse, longread, file("${data_id}_links.fasta") into files_assembled

        script:
        """
        echo ${longread} > longreads.txt
        perl ${LINKS} -f ${scaffolds} -s longreads.txt -b links
        mv links.scaffolds.fa ${data_id}_links.fasta
        """
    }

}

if (params.assembly == "canu") {
    
    process canu_parameters {
    
        output: 
        file('canu_settings.txt') into canu_settings

        """
        echo \
        'genomeSize = $params.genome_size 
        minReadLength=1000
        maxMemory=$params.mem 
        maxThread=$params.cpu' > canu_settings.txt
        """
    }

    process canu{
        tag{id}

        input:
        set id, sr1, sr2, lr from files_filtlong
        
        output: 
        set id, sr1, sr2, lr, file("${id}.contigs.fasta") into files_canu
        file("${id}.report")

        script:
        """
        $CANU -s ${canu_settings} -p ${data_id} -nanopore-raw ${lr}
        """
    }
}


if (params.assembly == 'canu'){
    
    process pilon{
        tag{id}

        input:
        set id, sr1, sr2, lr, contigs from files_canu

        output:
        set id, sr1, sr2, lr, file("after_polish.fasta") into files_assembled

        script:
        """
        ${BOWTIE2} --local --very-sensitive-local -I 0 -X 2000 -x ${contigs} \
        -1 ${sr1} -2 ${sr2} | samtools sort -o alignments.bam -T reads.tmp -;
        samtools index alignments.bam

        java -jar $PILON --genome ${contigs} --frags alignments.bam --changes \
        --output after_polish --fix all
        """

    }
}

process write_output{
    tag{data_id}
    
    publishDir "${params.outFolder}/${data_id}/final/", mode: 'copy'
    
    input:
    set dataid, forward, reverse, longread, scaffold from files_assembled

    output:
    file("${data_id}_final.fa")

    script:
    """
    mv ${scaffold} ${data_id}_final.fa    
    """
    
}


