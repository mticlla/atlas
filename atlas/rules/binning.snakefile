
SAMPLES=["S1"]
combined_contigs_folder=""
CONDAENV='../envs'




BINNING_BAMS=expand("{sample}/sequence_alignment/{sample}.bam", sample=SAMPLES[0])
BINNING_CONTIGS=expand("{sample}/{sample}_contigs.fasta",sample=SAMPLES[0])
BB_COVERAGE_FILES = expand("{sample}/assembly/contig_stats/postfilter_coverage_stats.txt",
    sample=SAMPLES)



config['binning_sensitivity'] = 'sensitive'
config["binning_min_contig_length"] =500

config['concoct']= {'Nexpected_clusters':200,
                        'read_length':150,
                        "Niterations":10}


config["maxbin"] ={"max_iteration": 1000,
                 "prob_threshold":0.5}

rule all:
    input:
        BINNING_CONTIGS,
        BINNING_BAMS,
        #expand("{folder}/binning/metabat/cluster_attribution.txt",folder=SAMPLES),
        expand("{folder}/binning/concoct/cluster_attribution.tsv",folder=SAMPLES)


localrules: make_maxbin_abundance_list
rule get_covarage_list:
    input:
        coverage = BB_COVERAGE_FILES
    output:
        abundance_file = expand("{{folder}}/binning/contig_coverages/{sample}.tsv", sample=SAMPLES),
        abundance_list = temp("{folder}/binning/maxbin/contig_coverage.list")
    run:
        with open(output.abundance_list, 'w') as outf:
            for i in range(len(input)):
                bb_cov_stats_to_maxbin(input.coverage[i], output.abundance_file[i])
                outf.write(os.path.abspath(output.abundance_file[i]) + '\n')







## CONCOCT

localrules: get_concoct_depth_file

rule get_coverage_files:
    input:
        covstats = BB_COVERAGE_FILES
    output:
        "{folder}/binning/contig_coverage/avarage_coverage_contigs.tsv",
        abundance_list= temp("{folder}/binning/contig_coverage/contig_coverage.list"),
        abundance_file = temp("{{folder}}/binning/contig_coverage/{sample}.tsv")

    params:
        sample_names =

    run:

        import pandas as pd
        import os

        combined_cov = {}

        for cov_file in input:

            sample = os.path.split(cov_file)[-1].split('_')[0]
            data = pd.read_table(cov_file, index_col=0)

            data.loc[data.Median_fold < 0, 'Median_fold'] = 0
            combined_cov[sample] = data.Median_fold




        pd.DataFrame(combined_cov).to_csv(output[0], sep='\t')




rule run_concoct:
    input:
        coverage = rules.get_concoct_depth_file.output,
        fasta = BINNING_CONTIGS
    output:
        "{{folder}}/binning/concoct/intermediate_files/clustering_gt{}.csv".format(config["binning_min_contig_length"])
    params:
        basename= lambda wc, output: os.path.dirname(output[0]),
        Nexpected_clusters= config['concoct']['Nexpected_clusters'],
        read_length= config['concoct']['read_length'],
        min_length=config["binning_min_contig_length"],
        niterations=config["concoct"]["Niterations"]
    benchmark:
        "logs/benchmarks/binning/concoct.txt"
    log:
        "{folder}/binning/concoct/log.txt"
    conda:
        "%s/concoct.yaml" % CONDAENV
    threads:
        10 # concoct uses 10 threads by default, wit for update: https://github.com/BinPro/CONCOCT/issues/177
    resources:
        mem = config["java_mem"]
    shell:
        """
        concoct -c {params.Nexpected_clusters}\
            --coverage_file {input.coverage}\
            --composition_file {input.fasta}\
            --basename {params.basename}\
            --read_length {params.read_length} \
            --length_threshold {params.min_length}\
            --converge_out \
            --iterations {params.niterations}
        """
localrules: get_cluster_attribution_concoct
rule get_cluster_attribution_concoct:
    input:
        rules.run_concoct.output[0]
    output:
        "{folder}/binning/concoct/cluster_attribution.tsv"
    run:
        with open(input[0]) as fin, open(output[0],'w') as fout:
            for line in fin:
                fout.write(line.replace(',','\t'))

## METABAT

rule get_metabat_depth_file:
    input:
        bam = BINNING_BAMS
    output:
        "{folder}/binning/metabat/metabat_depth.txt"
    log:
        "{folder}/binning/metabat/metabat.log"
    conda:
        "%s/metabat.yaml" % CONDAENV
    threads:
        config['threads']
    resources:
        mem = config["java_mem"]
    shell:
        """
        jgi_summarize_bam_contig_depths --outputDepth {output} {input.bam} &> >(tee {log})
        """

rule run_metabat:
    input:
        depth_file = rules.get_metabat_depth_file.output,
        contigs = BINNING_CONTIGS
    output:
        "{folder}/binning/metabat/cluster_attribution.txt",
    params:
          sensitivity = 500 if config['binning_sensitivity'] == 'sensitive' else 200,
          min_contig_len = config["binning_min_contig_length"],
          output_prefix = "{folder}/binning/bins/bin"
    benchmark:
        "logs/benchmarks/binning/metabat.txt"
    log:
        "logs/binning/metabat/run_metabat.txt"
    conda:
        "%s/metabat.yaml" % CONDAENV
    threads:
        config["threads"]
    resources:
        mem = config["java_mem"]
    shell:
          """
          metabat2 -i {input.contigs} \
          --abdFile {input.depth_file} \
          --minContig {params.min_contig_len} \
          --numThreads {threads} \
          --maxEdges {params.sensitivity} \
          --saveCls --noBinOut\
          -o {output} \
          &> >(tee {log})
          """
#
# localrules: MAG_analyze_metabat_clusters
# rule MAG_analyze_metabat_clusters:
#     input:
#         contigs = COMBINED_CONTIGS,
#         cluster_attribution_file = "{folder}/binning/metabat/metabat_cluster_attribution.txt".format(folder=combined_contigs_folder),
#         depth_file = "{folder}/binning/metabat_depth.txt".format(folder=combined_contigs_folder)
#     output:
#         expand("{folder}/binning/metabat/{file}", folder=combined_contigs_folder,
#                file=['cluster_attribution.txt',
#                      'contig_stats.tsv',
#                      'cluster_stats.tsv',
#                      'average_cluster_abundance.tsv',
#                      'average_contig_abundance.tsv.gz'])
#         # {folder}/binning/bins/MAG{id}.fasta
#     params:
#         output_prefix = lambda wc, output: os.path.join(os.path.dirname(output[0]), 'bins', 'Bin')
#     log:
#         "logs/binning/analyze_metabat_clusters.txt"
#     shell:
#         """
#             python %s/rules/analyze_metabat_clusters.py \
#             {input.contigs} \
#             {input.cluster_attribution_file} \
#             {input.depth_file} \
#             {params.output_prefix} \
#             2> >(tee {log})
#         """ % os.path.dirname(os.path.abspath(workflow.snakefile))
#
#
# # https://bitbucket.org/berkeleylab/metabat/wiki/Best%20Binning%20Practices
#


rule run_maxbin:
    input:
        fasta = BINNING_CONTIGS,
        abundance_list = rules.make_maxbin_abundance_list.output.abundance_list
    output:
        # fastas will need to be dynamic if we do something with them at a later time
        summary = "{folder}/binning/maxbin/bins/bin.summary",
        marker = "{folder}/binning/maxbin/bins/bin.marker",
        cluster_attribution_file = "{folder}/binning/maxbin/cluster_attribution.txt"
    params:
        mi = config["maxbin"]["max_iteration"],
        mcl = config["binning_min_contig_length"],
        pt = config["maxbin"]["prob_threshold"],
        out_prefix = lambda wildcards, output: os.path.splitext(os.path.dirname(output.summary))[0]
    log:
        "{folder}}/logs/maxbin2.log"
    conda:
        "%s/optional_genome_binning.yaml" % CONDAENV
    threads:
        config["threads"]
    shell:
        """run_MaxBin.pl -contig {input.fasta} \
               -abund_list {input.abundance_list} \
               -out {params.outdir} \
               -min_contig_length {params.mcl} \
               -thread {threads} \
               -prob_threshold {params.pt} \
               -max_iteration {params.mi} > {log}


            cp {params.output_prefix}.marker {input.cluster_attribution_file} 2>> {log}
        """

#
#
#
#
#
#     # rule MAG_initialize_checkm:
#     #     # input:
#     #     output:
#     #         touched_output = "logs/checkm_init.txt"
#     #     params:
#     #         database_dir = CHECKMDIR
#     #     conda:
#     #         "%s/optional_genome_binning.yaml" % CONDAENV
#     #     log:
#     #         "logs/initialize_checkm.log"
#     #     shell:
#     #         "python %s/rules/initialize_checkm.py {params.database_dir} {output.touched_output} {log}" % os.path.dirname(os.path.abspath(workflow.snakefile))
#
#
# rule MAG_run_checkm_lineage_wf:
#     input:
#         touched_output = "logs/checkm_init.txt",
#         bins = "{folder}/binning/cluster_attribution.txt".format(folder=combined_contigs_folder)
#     output:
#         "{folder}/binning/checkm/completeness.tsv".format(folder=combined_contigs_folder)
#     params:
#         bin_dir = lambda wc, input: os.path.join(os.path.dirname(input.bins),"bins"),
#         output_dir = lambda wc, output: os.path.dirname(output[0]),
#         fasta_extension = 'fasta'
#     conda:
#         "%s/optional_genome_binning.yaml" % CONDAENV
#     threads:
#         config.get("threads", 1)
#     resources:
#         mem= config.get('java_mem',JAVA_MEM)
#     shell:
#         """rm -r {params.output_dir} && \
#            checkm lineage_wf \
#                --file {params.output_dir}/completeness.tsv \
#                --tab_table \
#                --quiet \
#                --extension {params.fasta_extension} \
#                --threads {threads} \
#                {params.bin_dir} \
#                {params.output_dir}"""
#
#
# rule MAG_run_checkm_tree_qa:
#     input:
#         "{folder}/binning/checkm/completeness.tsv".format(folder=combined_contigs_folder)
#     output:
#         "{folder}/binning/checkm/taxonomy.tsv".format(folder=combined_contigs_folder)
#     params:
#         output_dir = lambda wc, output: os.path.dirname(output[0])
#     conda:
#         "%s/optional_genome_binning.yaml" % CONDAENV
#     shell:
#         """checkm tree_qa \
#                --tab_table \
#                --out_format 2 \
#                --file {params.output_dir}/taxonomy.tsv \
#                {params.output_dir}"""