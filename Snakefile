"""
Notes pertaining to eventual addition of Phinch compatible biom file...
otu.txt , commas to semicolons
biom convert -i otu.nocommas.txt -o some.biom --to-json
biom add-metadata -i some.biom -o phinch.biom --sample-metadata-fp tsv --output-as-json
#SampleID phinchID
"""
import os
from snakemake.utils import report
from subprocess import check_output


def get_samples(eid):
    samples = set()
    for f in os.listdir(os.path.join("results", eid, "demux")):
        if f.endswith("fastq") or f.endswith("fq"):
            samples.add(f.partition(".")[0].partition("_")[0])
    return samples


def fix_tax_entry(tax, kingdom=""):
    """
    >>> t = "p:Basidiomycota,c:Tremellomycetes,o:Tremellales,f:Tremellales_fam_Incertae_sedis,g:Cryptococcus"
    >>> fix_tax_entry(t, "Fungi")
    'k__Fungi,p__Basidiomycota,c__Tremellomycetes,o__Tremellales,f__Tremellales_fam_Incertae_sedis,g__Cryptococcus,s__'
    """
    if tax == "" or tax == "*":
        taxonomy = dict()
    else:
        taxonomy = dict(x.split(":") for x in tax.split(","))
    if "d" in taxonomy and not "k" in taxonomy:
        taxonomy["k"] = taxonomy["d"]
    else:
        taxonomy["k"] = kingdom

    new_taxonomy = []
    for idx in "kpcofgs":
        new_taxonomy.append("%s__%s" % (idx, taxonomy.get(idx, "")))
    return ",".join(new_taxonomy)


def fix_fasta_tax_entry(tax, kingdom=""):
    """
    >>> t = ">OTU_7;tax=p:Basidiomycota,c:Microbotryomycetes,o:Sporidiobolales,f:Sporidiobolales_fam_Incertae_sedis,g:Rhodotorula;"
    >>> fix_fasta_tax_entry(t)
    '>OTU_7;tax=k__,p__Basidiomycota,c__Microbotryomycetes,o__Sporidiobolales,f__Sporidiobolales_fam_Incertae_sedis,g__Rhodotorula,s__;'
    """
    toks = tax.split(";")
    otu = toks[0]
    tax_piece = toks[1]
    if not tax_piece.startswith("tax"):
        raise ValueError
    sequence_tax = tax_piece.split("=")[1]
    new_tax = fix_tax_entry(sequence_tax, kingdom)
    return "%s;tax=%s;" % (toks[0], new_tax)


# snakemake -s snakefile --configfile its.config.yaml
# configfile: "16s.config.yaml"
ruleorder: cluster_sequences > remove_chimeric_otus > utax > utax_unfiltered > fix_utax_taxonomy > fix_utax_taxonomy_unfiltered > compile_counts > compile_counts_unfiltered > biom > biom_unfiltered > multiple_align > multiple_align_unfiltered > newick_tree > newick_tree_unfiltered
USEARCH_VERSION = check_output("usearch --version", shell=True).strip()
CLUSTALO_VERSION = check_output("clustalo --version", shell=True).strip()
EID = config['eid']
SAMPLES = get_samples(EID)
# name output folder appropriately
CLUSTER_THRESHOLD = 100 - config['clustering']['percent_of_allowable_difference']


rule all:
    input:
        expand("results/{eid}/logs/quality_filtering_stats.txt", eid=EID),
        expand("results/{eid}/demux/{sample}_R1.fastq", eid=EID, sample=SAMPLES),
        expand("results/{eid}/demux/{sample}_R2.fastq", eid=EID, sample=SAMPLES),
        expand("results/{eid}/{pid}/OTU.txt", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU.biom", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU_tax.txt", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU.tree", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU_unfiltered.txt", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU_unfiltered.biom", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU_unfiltered_tax.txt", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/OTU_unfiltered.tree", eid=EID, pid=CLUSTER_THRESHOLD),
        expand("results/{eid}/{pid}/README.html", eid=EID, pid=CLUSTER_THRESHOLD)


rule make_tax_database:
    input:
        fasta = config['taxonomy_database']['fasta'],
        trained_parameters = config['taxonomy_database']['trained_parameters']
    output:
        os.path.splitext(config['taxonomy_database']['trained_parameters'])[0] + '.udb'
    version: USEARCH_VERSION
    message: "Creating a UTAX database trained on {input.fasta} using {input.trained_parameters}"
    shell:
        '''
        usearch -makeudb_utax {input.fasta} -taxconfsin {input.trained_parameters} -output {output}
        '''


rule make_uchime_database:
    input: config['chimera_database']['fasta']
    output: os.path.splitext(config['chimera_database']['fasta'])[0] + '.udb'
    version: USEARCH_VERSION
    message: "Creating chimera reference index based on {input}"
    shell: "usearch -makeudb_usearch {input} -output {output}"


rule count_raw_reads:
    input:
        "results/{eid}/demux/{sample}_R1.fastq"
    output:
        "results/{eid}/demux/{sample}_R1.fastq.count"
    shell:
        "awk '{{n++}}END{{print n/4}}' {input} > {output}"


rule quality_filter_reads:
    input:
        r1 = "results/{eid}/demux/{sample}_R1.fastq",
        r2 = "results/{eid}/demux/{sample}_R2.fastq"
    output:
        r1 = temp("results/{eid}/{sample}_filtered_R1.fastq"),
        r2 = temp("results/{eid}/{sample}_filtered_R2.fastq"),
        stats = temp("results/{eid}/{sample}_quality_filtering_stats.txt")
    message: "Filtering reads using BBDuk2 to remove adapters and phiX with matching kmer length of {params.k} at a hamming distance of {params.hdist} and quality trim both ends to Q{params.quality}. Reads shorter than {params.minlength} were discarded."
    params:
        adapters = config['filtering']['adapters'],
        quality = config['filtering']['minimum_base_quality'],
        hdist = config['filtering']['allowable_kmer_mismatches'],
        k = config['filtering']['reference_kmer_match_length'],
        qtrim = "rl",
        ktrim = "l",
        minlength = config['filtering']['minimum_passing_read_length']
    threads: 4
    shell:
        '''
        bbduk2.sh -Xmx8g in={input.r1} in2={input.r2} out={output.r1} out2={output.r2} \
            fref={params.adapters} stats={output.stats} hdist={params.hdist} k={params.k} \
            trimq={params.quality} qtrim={params.qtrim} threads={threads} ktrim={params.ktrim} \
            minlength={params.minlength}
        '''


rule count_filtered_reads:
    input:
        "results/{eid}/{sample}_filtered_R1.fastq"
    output:
        temp("results/{eid}/{sample}_filtered_R1.fastq.count")
    shell:
        "awk '{{n++}}END{{print n/4}}' {input} > {output}"


rule combine_filtering_stats:
    input: expand("results/{eid}/{sample}_quality_filtering_stats.txt", eid=EID, sample=SAMPLES)
    output: "results/{eid}/logs/quality_filtering_stats.txt".format(eid=EID)
    shell: "cat {input} > {output}"


rule merge_reads:
    input:
        r1 = "results/{eid}/{sample}_filtered_R1.fastq",
        r2 = "results/{eid}/{sample}_filtered_R2.fastq"
    output: temp("results/{eid}/{sample}_merged.fastq")
    version: USEARCH_VERSION
    message: "Merging paired-end reads with USEARCH at a minimum merge length of {params.minimum_merge_length}"
    params:
        minimum_merge_length = config['merging']['minimum_merge_length']
    shell:
        '''
        usearch -fastq_mergepairs {input.r1} -relabel @ -sample {wildcards.sample} \
            -fastq_minmergelen {params.minimum_merge_length} \
            -fastqout {output}
        '''


rule count_joined_reads:
    input:
        "results/{eid}/{sample}_merged.fastq"
    output:
        temp("results/{eid}/{sample}_merged.fastq.count")
    shell:
        "awk '{{n++}}END{{print n/4}}' {input} > {output}"


rule combine_merged_reads:
    input: expand("results/{eid}/{sample}_merged.fastq", eid=EID, sample=SAMPLES)
    output: "results/{eid}/merged.fastq"
    message: "Concatenating the merged reads into a single file"
    shell: "cat {input} > {output}"


rule fastq_filter:
    input: "results/{eid}/merged.fastq"
    output: "results/{eid}/merged_%f.fasta" % config['filtering']['maximum_expected_error']
    version: USEARCH_VERSION
    message: "Filtering FASTQ with USEARCH with an expected maximum error rate of {params.maxee}"
    params:
        maxee = config['filtering']['maximum_expected_error']
    shell: "usearch -fastq_filter {input} -fastq_maxee {params.maxee} -fastaout {output} -relabel Filt"


rule dereplicate_sequences:
    input: "results/{eid}/merged_%f.fasta" % config['filtering']['maximum_expected_error']
    output: temp("results/{eid}/uniques.fasta")
    version: USEARCH_VERSION
    message: "Dereplicating with USEARCH"
    shell: "usearch -derep_fulllength {input} -sizeout -relabel Uniq -fastaout {output}"


rule cluster_sequences:
    input: "results/{eid}/uniques.fasta"
    output: "results/{eid}/{pid}/OTU_unfiltered.fasta"
    version: USEARCH_VERSION
    message: "Clustering sequences with USEARCH where OTUs have a minimum size of {params.minsize} and where the maximum difference between an OTU member sequence and the representative sequence of that OTU is {params.otu_radius_pct}%"
    params:
        minsize = config['clustering']['minimum_sequence_abundance'],
        otu_radius_pct = config['clustering']['percent_of_allowable_difference']
    shell:
        '''
        usearch -cluster_otus {input} -minsize {params.minsize} -otus {output} -relabel OTU_ \
            -otu_radius_pct {params.otu_radius_pct}
        '''


rule remove_chimeric_otus:
    input:
        fasta = "results/{eid}/{pid}/OTU_unfiltered.fasta",
        reference = rules.make_uchime_database.output
    output: "results/{eid}/{pid}/OTU.fasta"
    version: USEARCH_VERSION
    message: "Chimera filtering OTU seed sequences against %s" % config['chimera_database']['metadata']
    threads: 12
    log: "results/{eid}/{pid}/logs/uchime_ref.log"
    shell:
        '''usearch -uchime_ref {input.fasta} -db {input.reference} -nonchimeras	{output} \
            -strand plus -threads {threads} 2> {log}
        '''


rule utax:
    input:
        fasta = "results/{eid}/{pid}/OTU.fasta",
        db = rules.make_tax_database.output
    output:
        fasta = "results/{eid}/{pid}/utax/OTU_tax.fasta",
        txt = "results/{eid}/{pid}/utax/OTU_tax.txt"
    version: USEARCH_VERSION
    message: "Assigning taxonomies with UTAX algorithm using USEARCH with a confidence cutoff of {params.utax_cutoff}"
    params:
        utax_cutoff = config['taxonomy']['prediction_confidence_cutoff']
    threads: 12
    log: "results/{eid}/{pid}/logs/utax.log"
    shell:
        '''
        usearch -utax {input.fasta} -db {input.db} -strand both -threads {threads} \
            -fastaout {output.fasta} -utax_cutoff {params.utax_cutoff} \
            -utaxout {output.txt} 2> {log}
        '''


rule utax_unfiltered:
    input:
        fasta = "results/{eid}/{pid}/OTU_unfiltered.fasta",
        db = rules.make_tax_database.output
    output:
        fasta = "results/{eid}/{pid}/utax/OTU_unfiltered_tax.fasta",
        txt = "results/{eid}/{pid}/utax/OTU_unfiltered_tax.txt"
    version: USEARCH_VERSION
    message: "Assigning taxonomies with UTAX algorithm using USEARCH with a confidence cutoff of {params.utax_cutoff}"
    params:
        utax_cutoff = config['taxonomy']['prediction_confidence_cutoff']
    threads: 12
    log: "results/{eid}/{pid}/logs/unfiltered_utax.log"
    shell:
        '''
        usearch -utax {input.fasta} -db {input.db} -strand both -threads {threads} \
            -fastaout {output.fasta} -utax_cutoff {params.utax_cutoff} \
            -utaxout {output.txt} 2> {log}
        '''


rule fix_utax_taxonomy:
    input:
        fasta = "results/{eid}/{pid}/utax/OTU_tax.fasta",
        txt = "results/{eid}/{pid}/utax/OTU_tax.txt"
    output:
        fasta = "results/{eid}/{pid}/OTU_tax.fasta",
        txt = "results/{eid}/{pid}/OTU_tax.txt"
    params:
        kingdom = config['kingdom']
    message: "Altering taxa to reflect QIIME style annotation"
    run:
        with open(input.fasta) as ifh, open(output.fasta, 'w') as ofh:
            for line in ifh:
                line = line.strip()
                if not line.startswith(">OTU_"):
                    print(line, file=ofh)
                else:
                    print(fix_fasta_tax_entry(line, params.kingdom), file=ofh)
        with open(input.txt) as ifh, open(output.txt, 'w') as ofh:
            for line in ifh:
                toks = line.strip().split("\t")
                print(toks[0], fix_tax_entry(toks[1], params.kingdom),
                      fix_tax_entry(toks[2], params.kingdom), toks[3], sep="\t", file=ofh)


rule fix_utax_taxonomy_unfiltered:
    input:
        fasta = "results/{eid}/{pid}/utax/OTU_unfiltered_tax.fasta",
        txt = "results/{eid}/{pid}/utax/OTU_unfiltered_tax.txt"
    output:
        fasta = "results/{eid}/{pid}/OTU_unfiltered_tax.fasta",
        txt = "results/{eid}/{pid}/OTU_unfiltered_tax.txt"
    params:
        kingdom = config['kingdom']
    message: "Altering taxa to reflect QIIME style annotation"
    run:
        with open(input.fasta) as ifh, open(output.fasta, 'w') as ofh:
            for line in ifh:
                line = line.strip()
                if not line.startswith(">OTU_"):
                    print(line, file=ofh)
                else:
                    print(fix_fasta_tax_entry(line, params.kingdom), file=ofh)
        with open(input.txt) as ifh, open(output.txt, 'w') as ofh:
            for line in ifh:
                toks = line.strip().split("\t")
                print(toks[0], fix_tax_entry(toks[1], params.kingdom),
                      fix_tax_entry(toks[2], params.kingdom), toks[3], sep="\t", file=ofh)


rule compile_counts:
    input:
        fastq = "results/{eid}/merged.fastq",
        db = "results/{eid}/{pid}/OTU_tax.fasta",
    output:
        txt = "results/{eid}/{pid}/OTU.txt",
    params:
        threshold = config['mapping_to_otus']['read_identity_requirement']
    threads: 12
    shell:
        '''
        usearch -usearch_global {input.fastq} -db {input.db} -strand plus \
            -id {params.threshold} -otutabout {output.txt} \
            -threads {threads}
        '''


rule compile_counts_unfiltered:
    input:
        fastq = "results/{eid}/merged.fastq",
        db = "results/{eid}/{pid}/OTU_unfiltered_tax.fasta",
    output:
        txt = "results/{eid}/{pid}/OTU_unfiltered.txt",
    params:
        threshold = config['mapping_to_otus']['read_identity_requirement']
    threads: 12
    shell:
        '''
        usearch -usearch_global {input.fastq} -db {input.db} -strand plus \
            -id {params.threshold} -otutabout {output.txt} \
            -threads {threads}
        '''


rule biom:
    input:
        "results/{eid}/{pid}/OTU.txt"
    output:
        "results/{eid}/{pid}/OTU.biom"
    shell:
        '''
        sed 's|\"||g' {input} | sed 's|\,|\;|g' > results/{wildcards.eid}/{wildcards.pid}/OTU_converted.txt
        biom convert -i results/{wildcards.eid}/{wildcards.pid}/OTU_converted.txt \
            -o {output} --to-json \
            --process-obs-metadata sc_separated --table-type "OTU table"
        '''


rule biom_unfiltered:
    input:
        "results/{eid}/{pid}/OTU_unfiltered.txt"
    output:
        "results/{eid}/{pid}/OTU_unfiltered.biom"
    shell:
        '''
        sed 's|\"||g' {input} | sed 's|\,|\;|g' > results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.txt
        biom convert -i results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.txt \
            -o results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.biom --to-json \
            --process-obs-metadata sc_separated
        sed 's|\"type\": \"Table\"|\"type\": \"OTU table\"|g' results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.biom > {output}
        rm results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.txt results/{wildcards.eid}/{wildcards.pid}/OTU_unfiltered_converted.biom
        '''


rule multiple_align:
    input: "results/{eid}/{pid}/OTU.fasta"
    output: "results/{eid}/{pid}/OTU_aligned.fasta"
    message: "Multiple alignment of samples using Clustal Omega"
    version: CLUSTALO_VERSION
    threads: 12
    shell:
        '''
        /people/brow015/apps/cbb/clustalo/1.2.0/clustalo -i {input} -o {output} \
            --outfmt=fasta --threads {threads} --force
        '''


rule multiple_align_unfiltered:
    input: "results/{eid}/{pid}/OTU_unfiltered.fasta"
    output: "results/{eid}/{pid}/OTU_unfiltered_aligned.fasta"
    message: "Multiple alignment of samples using Clustal Omega"
    version: CLUSTALO_VERSION
    threads: 12
    shell:
        '''
        /people/brow015/apps/cbb/clustalo/1.2.0/clustalo -i {input} -o {output} \
            --outfmt=fasta --threads {threads} --force
        '''


rule newick_tree:
    input: "results/{eid}/{pid}/OTU_aligned.fasta"
    output: "results/{eid}/{pid}/OTU.tree"
    message: "Building tree from aligned OTU sequences with FastTree2"
    log: "results/{eid}/{pid}/logs/fasttree.log"
    shell: "FastTree -nt -gamma -spr 4 -log {log} -quiet {input} > {output}"


rule newick_tree_unfiltered:
    input: "results/{eid}/{pid}/OTU_unfiltered_aligned.fasta"
    output: "results/{eid}/{pid}/OTU_unfiltered.tree"
    message: "Building tree from aligned OTU sequences with FastTree2"
    log: "results/{eid}/{pid}/logs/fasttree.log"
    shell: "FastTree -nt -gamma -spr 4 -log {log} -quiet {input} > {output}"


rule report:
    input:
        file1 = "results/{eid}/{pid}/OTU.biom",
        file2 = "results/{eid}/{pid}/OTU.txt",
        file3 = "results/{eid}/{pid}/OTU_tax.fasta",
        file4 = "results/{eid}/{pid}/OTU_tax.txt",
        file5 = "results/{eid}/{pid}/OTU.tree",
        raw_counts = "results/{eid}/demux/{sample}_R1.fastq.count",
        filtered_counts = "results/{eid}/{sample}_filtered_R1.fastq.count",
        merged_counts = "results/{eid}/{sample}_merged.fastq.count"
    shadow: "shallow"
    params:
        kmer_len = config['filtering']['reference_kmer_match_length'],
        ham_dist = config['filtering']['allowable_kmer_mismatches'],
        min_read_len = config['filtering']['minimum_passing_read_length'],
        min_merge_len = config['merging']['minimum_merge_length'],
        max_ee = config['filtering']['maximum_expected_error'],
        tax_cutoff = config['taxonomy']['prediction_confidence_cutoff'],
        min_seq_abundance = config['clustering']['minimum_sequence_abundance'],
        tax_metadata = config['taxonomy_database']['metadata'],
        tax_citation = config['taxonomy_database']['citation'],
        chimera_metadata = config['chimera_database']['metadata'],
        chimera_citation = config['chimera_database']['citation'],
        samples = SAMPLES
    output:
        html = "results/{eid}/{pid}/README.html"
    run:
        from biom import parse_table
        from biom.util import compute_counts_per_sample_stats
        from operator import itemgetter
        from numpy import std

        summary_csv = "stats.csv"
        sample_summary_csv = "samplesummary.csv"
        samples_csv = "samples.csv"
        biom_per_sample_counts = {}
        with open(input.file1) as fh, open(summary_csv, 'w') as sumout, open(samples_csv, 'w') as samout, open(sample_summary_csv, 'w') as samplesum:
            bt = parse_table(fh)
            print("Samples", len(bt.ids()), sep=",", file=sumout)
            print("OTUs", len(bt.ids(axis='observation')), sep=",", file=sumout)

            stats = compute_counts_per_sample_stats(bt)
            biom_per_sample_counts = stats[4]
            sample_counts = list(stats[4].values())
            print("Total Count", sum(sample_counts), sep=",", file=sumout)
            print("Table Density (fraction of non-zero)", bt.get_table_density(), sep=",", file=sumout)

            print("Minimum Count", stats[0], sep=",", file=samplesum)
            print("Maximum Count", stats[1], sep=",", file=samplesum)
            print("Median", stats[2], sep=",", file=samplesum)
            print("Mean", stats[3], sep=",", file=samplesum)
            print("Standard Deviation", std(sample_counts), sep=",", file=samplesum)

            for k, v in sorted(stats[4].items(), key=itemgetter(1)):
                print(k, '%1.1f' % v, sep=",", file=samout)

        raw_counts = []
        filtered_counts = []
        merged_counts = []
        biom_counts = []

        for sample in params.samples:
            # get raw count
            for f in input.raw_counts:
                if sample in f:
                    with open(f) as fh:
                        for line in fh:
                            raw_counts.append(int(line.strip()))
                            break
            # filtered count
            for f in input.filtered_counts:
                if sample in f:
                    with open(f) as fh:
                        for line in fh:
                            filtered_counts.append(int(line.strip()))
                            break
            # merged count
            for f in input.merged_counts:
                if sample in f:
                    with open(f) as fh:
                        for line in fh:
                            merged_counts.append(int(line.strip()))
                            break
            # read count contribution to OTUs
            biom_counts.append(biom_per_sample_counts[sample])
        assert len(raw_counts) == len(filtered_counts) == len(merged_counts) == len(biom_counts)

        samples_str = "['%s']" % "', '".join(map(str, params.samples))
        raw_counts_str = "[%s]" % ", ".join(map(str, raw_counts))
        filtered_counts_str = "[%s]" % ", ".join(map(str, filtered_counts))
        merged_counts_str = "[%s]" % ", ".join(map(str, merged_counts))
        biom_counts_str = "[%s]" % ", ".join(map(str, biom_counts))

        report("""
        =============================================================
        README - {wildcards.eid}
        =============================================================

        .. raw:: html

            <script src="https://code.highcharts.com/highcharts.js"></script>
            <script src="https://code.highcharts.com/modules/exporting.js"></script>

        .. contents::
            :backlinks: none

        Summary
        -------

        .. csv-table::
            :file: {summary_csv}

        Surviving Reads Per Sample
        **************************

        .. csv-table::
            :file: {sample_summary_csv}

        .. raw:: html

            <script type="text/javascript">
            $(function () {
                $('#count-plot').highcharts({
                    chart: {
                        type: 'column'
                    },
                    title: {
                        text: 'Sample Sequence Counts'
                    },
                    xAxis: {
                        categories: {samples_str},
                        crosshair: true
                    },
                    yAxis: {
                        min: 0,
                        title: {
                            text: 'Count'
                        }
                    },
                    tooltip: {
                        headerFormat: '<span style="font-size:10px">{{point.key}}</span><table>',
                        pointFormat: '<tr><td style="color:{series.color};padding:0">{{series.name}}: </td>' +
                            '<td style="padding:0"><b>{{point.y:.1f}}</b></td></tr>',
                        footerFormat: '</table>',
                        shared: true,
                        useHTML: true
                    },
                    credits: {
                        enabled: false
                    },
                    plotOptions: {
                        column: {
                            pointPadding: 0.2,
                            borderWidth: 0
                        }
                    },
                    series: [{
                                name: 'Raw',
                                data: {raw_counts_str}
                            },
                            {
                                name: 'Filtered',
                                data: {filtered_counts_str}
                            },
                            {
                                name: 'Merged',
                                data: {merged_counts_str}
                            },
                            {
                                name: 'Assigned to OTUs',
                                data: {biom_counts_str}
                            }]
                    });
            });
            </script>

        .. raw:: html

            <div id="count-plot" style="min-width: 310px; height: 400px; margin: 0 auto"></div>


        Output
        ------

        These files fall downstream of reference-based chimera removal. Non-chimera removed OTU
        data is also available in the results directory.

        Chimera Removal
        ***************

        This occurs de novo during clustering and reference-based post clustering on the OTU seed
        sequences.

        Chimera database - {params.chimera_metadata}

        | {params.chimera_citation}

        Biom Table
        **********

        Counts observed per sample as represented in the biom file (file1_). This count is
        representative of quality filtered reads that were assigned per sample to OTU seed
        sequences.

        .. csv-table:: Per Sample Count
            :header: "Sample ID", "Count"
            :file: {samples_csv}

        OTU Table
        *********

        Tab delimited table of OTU and abundance per sample (file2_). The final column is the
        taxonomy assignment of the given OTU.

        Taxonomy was assigned to the OTU sequences at a cutoff of {params.tax_cutoff}%. The
        confidence values can be observed within attached file4_.

        Taxonomy database - {params.tax_metadata}

        | {params.tax_citation}

        OTU Sequences
        *************

        The OTU sequences in FASTA format (file3_) and aligned as newick tree (file5_).

        To build the tree, sequences were aligned using Clustalo (Sievers et al., 2011) and
        FastTree2 (Price, et al., 2010) was used to generate the phylogenetic tree.

        | Sievers F, Wilm A, Dineen D, Gibson TJ, Karplus K, Li W, Lopez R, McWilliam H, Remmert M,
          Söding J, et al. 2011. Fast, scalable generation of high-quality protein multiple
          sequence alignments using Clustal Omega. Mol Syst Biol 7: 539
        | Price MN, Dehal PS, Arkin AP. 2010. FastTree 2--approximately maximum-likelihood trees
          for large alignments. ed. A.F.Y. Poon. PLoS One 5: e9490


        Methods
        -------

        Raw sequence reads were demultiplexed with using EA-Utils (Aronesty, 2013) with zero
        mismatches allowed in the barcode sequence. Reads were quality filtered with BBDuk2 (Bushnell,
        2014) to remove adapter sequences and PhiX with matching kmer length of {params.kmer_len}
        bp at a hamming distance of {params.ham_dist}. Reads shorter than {params.min_read_len} bp
        were discarded. Reads were merged using USEARCH (Edgar, 2010) with a minimum length
        threshold of {params.min_merge_len} bp and maximum error rate of {params.max_ee}%. Sequences
        were dereplicated (minimum sequence abundance = {params.min_seq_abundance}) and clustered
        using the distance-based, greedy clustering method of USEARCH (Edgar, 2013) at
        {wildcards.pid}% pairwise sequence identity among operational taxonomic unit (OTU) member
        sequences. De novo prediction of chimeric sequences was performed using USEARCH during
        clustering. Taxonomy was assigned to OTU sequences at a minimum identity cutoff fraction of
        {params.tax_cutoff} using the global alignment method implemented in USEARCH across
        {params.tax_metadata}. OTU seed sequences were filtered against {params.chimera_metadata}
        to identify chimeric OTUs using USEARCH.


        | Erik Aronesty (2013). TOBioiJ : "Comparison of Sequencing Utility Programs",
          DOI:10.2174/1875036201307010001
        | Bushnell, B. (2014). BBMap: A Fast, Accurate, Splice-Aware Aligner.
          URL https://sourceforge.net/projects/bbmap/
        | Edgar, RC (2010). Search and clustering orders of magnitude faster than BLAST,
          Bioinformatics 26(19), 2460-2461. doi: 10.1093/bioinformatics/btq461
        | Edgar, RC (2013). UPARSE: highly accurate OTU sequences from microbial amplicon reads.
          Nat Methods.

        """, output.html, metadata="Author: Joe Brown (joe.brown@pnnl.gov)", file1=input.file1,
        file2=input.file2, file3=input.file3, file4=input.file4, file5=input.file5)