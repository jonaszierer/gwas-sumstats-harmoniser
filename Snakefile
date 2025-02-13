# Configure --------------------------------------------------------------------

#configfile: "config.yaml"

#singularity: "docker://ebispot/gwas-sumstats-harmoniser:latest"

rule get_vcf_files:
    output:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz", local=config["local_resources"])
    params:
        remote_location=config["remote_vcf_location"],
        local_resources=config["local_resources"]
    shell:
        "mkdir -p {params.local_resources}; "
        "wget -P {params.local_resources} {params.remote_location}/homo_sapiens-chr{wildcards.chromosome}.vcf.gz"


rule get_tbi_files:
    output:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz.tbi", local=config["local_resources"])
    params:
        local_resources=config["local_resources"]
    shell:
        "tabix -p vcf {params.local_resources}/homo_sapiens-chr{wildcards.chromosome}.vcf.gz"


rule make_parquet_refs:
    input:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz", local=config["local_resources"])
    output:
        expand("{local}homo_sapiens-chr{{chromosome}}.parquet", local=config["local_resources"])
    params:
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    shell:
        "python {params.repo_path}/harmoniser/vcf2parquet.py -f {params.local_resources}homo_sapiens-chr{wildcards.chromosome}.vcf.gz"


rule map_to_build:
    input:
        expand("{local}homo_sapiens-chr{chromosome}.parquet", chromosome=config["chromosomes"], local=config["local_resources"]),
        in_ss="{ss_file}.tsv"
    output:
        expand("{{ss_file}}/{chromosome}.merged", chromosome=config["chromosomes"])
    params:
        local_resources=config["local_resources"],
        to_build=config["desired_build"],
        repo_path=config["repo_path"]
    resources:
        mem_mb = lambda wildcards, attempt: attempt * 28000
    shell:
        "filename={wildcards.ss_file}; "
        "from_build=$(echo -n $filename | tail -c 2); "
        "mkdir -p {wildcards.ss_file}; "
        "python {params.repo_path}/harmoniser/map_to_build.py -f {input.in_ss} "
        "-from_build $from_build "
        "-to_build {params.to_build} "
        "-vcf '{params.local_resources}/homo_sapiens-chr*.parquet'"

rule ten_percent_generate_strand_counts:
    input:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz", local=config["local_resources"]),
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz.tbi", local=config["local_resources"]),
        in_ss="{ss_file}/{chromosome}.merged"
    output:
        "{ss_file}/10percent.{chromosome}.merged.sc"
    params:
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    shell:
        "select=$[$(wc -l < {input.in_ss})]; "
        "if [ $[$select/10] -gt 100 ]; then n=$[$select/10]; else n=$select; fi; "
        "(head -n 1 {input.in_ss}; sed '1d' {input.in_ss} | shuf -n $n)>{wildcards.ss_file}/10percent.{wildcards.chromosome}.merged;"
        "python {params.repo_path}/harmoniser/genetics-sumstat-harmoniser/sumstat_harmoniser/main.py --sumstats {wildcards.ss_file}/10percent.{wildcards.chromosome}.merged "
        "--vcf {params.local_resources}homo_sapiens-chr{wildcards.chromosome}.vcf.gz "
        "--chrom_col chromosome "
        "--pos_col base_pair_location "
        "--effAl_col effect_allele "
        "--otherAl_col other_allele "
        "--rsid_col variant_id "
        "--strand_counts {wildcards.ss_file}/10percent.{wildcards.chromosome}.merged.sc"

rule ten_percent_summarise_strand_counts:
    input:
        expand("{{ss_file}}/10percent.{chromosome}.merged.sc", chromosome=config["chromosomes"])
    output:
        "{ss_file}/10_percent_total_strand_count.tsv"
    params:
        repo_path=config["repo_path"]
    shell:
        "python {params.repo_path}/harmoniser/sum_strand_counts_10percent.py -i {wildcards.ss_file} -o {wildcards.ss_file} -config {params.repo_path}/config.yaml"

rule generate_strand_counts:
    input:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz", local=config["local_resources"]),
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz.tbi", local=config["local_resources"]),
        in_ss="{ss_file}/{chromosome}.merged",
        sc_sum="{ss_file}/10_percent_total_strand_count.tsv",
        ten_ss="{ss_file}/10percent.{chromosome}.merged.sc",
    output:
        "{ss_file}/full.{chromosome}.merged.sc"
    params:
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    shell:
        "if [ `grep -c rerun {input.sc_sum}` == '0' ];then rename.ul 10percent full {input.ten_ss}; else "
        "python {params.repo_path}/harmoniser/genetics-sumstat-harmoniser/sumstat_harmoniser/main.py --sumstats {input.in_ss} "
        "--vcf {params.local_resources}homo_sapiens-chr{wildcards.chromosome}.vcf.gz "
        "--chrom_col chromosome "
        "--pos_col base_pair_location "
        "--effAl_col effect_allele "
        "--otherAl_col other_allele "
        "--rsid_col variant_id "
        "--strand_counts {wildcards.ss_file}/full.{wildcards.chromosome}.merged.sc; fi"


rule summarise_strand_counts:
    input:
        expand("{{ss_file}}/full.{chromosome}.merged.sc", chromosome=config["chromosomes"]),
        sc_sum="{ss_file}/10_percent_total_strand_count.tsv"
    output:
        "{ss_file}/total_strand_count.tsv"
    params:
        repo_path=config["repo_path"]
    shell:
        "if [ `grep -c rerun {input.sc_sum}` == '0' ];then cp {input.sc_sum} {wildcards.ss_file}/total_strand_count.tsv; else "
        "python {params.repo_path}/harmoniser/sum_strand_counts.py -i {wildcards.ss_file} -o {wildcards.ss_file} -config {params.repo_path}/config.yaml;fi"

rule log_palindromic:
    input:
        expand("{local}homo_sapiens-chr22.vcf.gz", local=config["local_resources"]),
        sc_sum="{ss_file}/total_strand_count.tsv"
    output:
        "{ss_file}/running.log"
    params:
        local_resources=config["local_resources"]
    shell:
        "palin_mode=$(grep palin_mode {wildcards.ss_file}/total_strand_count.tsv | cut -f2);"
        "ratio=$(grep ratio {wildcards.ss_file}/total_strand_count.tsv);"
        "echo The direction of palindromic SNPs infers as $palin_mode by $ratio > {wildcards.ss_file}/running.log;"
        "echo reference: >> {wildcards.ss_file}/running.log;"
        "echo '################################################################' >> {wildcards.ss_file}/running.log;"
        "echo $(less {params.local_resources}homo_sapiens-chr22.vcf.gz | head -n 1000 | grep ^# | grep source) >> {wildcards.ss_file}/running.log;"
        "echo $(less {params.local_resources}homo_sapiens-chr22.vcf.gz | head -n 1000 | grep ^# | grep reference) >> {wildcards.ss_file}/running.log;"
        "echo $(less {params.local_resources}homo_sapiens-chr22.vcf.gz | head -n 1000 | grep ^# | grep dbSNP | sed 's/INFO=<//g' | sed 's/>//g' )>> {wildcards.ss_file}/running.log;"
        "echo '################################################################' >> {wildcards.ss_file}/running.log;"

rule harmonisation:
    input:
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz", local=config["local_resources"]),
        expand("{local}homo_sapiens-chr{{chromosome}}.vcf.gz.tbi", local=config["local_resources"]),
        in_ss="{ss_file}/{chromosome}.merged",
        sc_sum="{ss_file}/total_strand_count.tsv",
        log="{ss_file}/running.log"
    output:
        "{ss_file}/{chromosome}.merged.hm"
    params:
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    shell:
        "palin_mode=$(grep palin_mode {input.sc_sum} | cut -f2 );"
        "python {params.repo_path}/harmoniser/genetics-sumstat-harmoniser/sumstat_harmoniser/main.py --sumstats {input.in_ss} "
        "--vcf {params.local_resources}homo_sapiens-chr{wildcards.chromosome}.vcf.gz "
        "--hm_sumstats {wildcards.ss_file}/{wildcards.chromosome}.merged.hm "
        "--hm_statfile {wildcards.ss_file}/{wildcards.chromosome}.merged.log.tsv.gz "
        "--chrom_col chromosome "
        "--pos_col base_pair_location "
        "--effAl_col effect_allele "
        "--otherAl_col other_allele "
        "--rsid_col variant_id "
        "--beta_col beta "
        "--or_col odds_ratio "
        "--or_col_lower ci_lower "
        "--or_col_upper ci_upper "
        "--eaf_col effect_allele_frequency "
        "--na_rep_in NA "
        "--na_rep_out NA "
        "--palin_mode $palin_mode"


rule concatenate_chr_splits:
    input:
        expand("{{ss_file}}/{chromosome}.merged.hm", chromosome=config["chromosomes"])
    output:
        "{ss_file}/harmonised.tsv"
    params:
        repo_path=config["repo_path"]
    shell:
        "{params.repo_path}/harmoniser/cat_chroms.sh {wildcards.ss_file}"

rule get_variation_tables:
    output:
        expand("{local}variation.txt.gz", local=config["local_resources"]),
        expand("{local}variation_synonym.txt.gz", local=config["local_resources"])
    params:
        remote_location=config["remote_ensembl_variation"],
        local_resources=config["local_resources"]
    shell:
        "wget -P {params.local_resources} {params.remote_location}variation.txt.gz; "
        "wget -P {params.local_resources} {params.remote_location}variation_synonym.txt.gz"


rule make_local_synonyms_table:
    input:
        expand("{local}variation.txt.gz", local=config["local_resources"]),
        expand("{local}variation_synonym.txt.gz", local=config["local_resources"])
    output:
        expand("{local}rsID.sql", local=config["local_resources"])
    params:
        remote_location=config["remote_ensembl_variation"],
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    resources:
        mem_mb = lambda wildcards, attempt: attempt * 12000
    shell:
        "python {params.repo_path}/harmoniser/make_synonym_table.py -f {params.local_resources}variation.txt.gz -id_col 0 -name_col 2 -db {params.local_resources}rsID.sql; "
        "python {params.repo_path}/harmoniser/make_synonym_table.py -f {params.local_resources}variation_synonym.txt.gz -id_col 1 -name_col 4 -db {params.local_resources}rsID.sql; "
        "python {params.repo_path}/harmoniser/make_synonym_table.py -index -db {params.local_resources}/rsID.sql"


rule qc:
    input:
        in_ss="{ss_file}/harmonised.tsv",
        db=expand("{local}rsID.sql", local=config["local_resources"]) if config["local_synonyms"] else []
    output:
        "{ss_file}/harmonised.qc.tsv"
    params:
        local_resources=config["local_resources"],
        repo_path=config["repo_path"]
    shell:
        "python {params.repo_path}/harmoniser/basic_qc.py -f {input.in_ss} -d {wildcards.ss_file}/ --log {wildcards.ss_file}/report.txt -db {input.db}"
