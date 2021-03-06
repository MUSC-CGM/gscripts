# ALWAYS set SAMPLE
SAMPLE = &SAMPLE

# SOMETIMES change SPECIES 
snpEffDB = &snpEffDB
# hg19

SNP_DB = &SNP_DB
# /projects/ps-yeolab/genomes/hg19/snp137.txt.gz

FA = &FA
# /projects/ps-yeolab/genomes/hg19/chromosomes/all.fa

# RARELY change OPTIONS
S = &S
# s # for TruSeq, S for Balaji's library prep

MinCoverage = &MinCoverage
# 5
MinConfidence = &MinConfidence
# 0.995
MinEditFrac = &MinEditFrac
# 0.1
pseudoG = &pseudoG
# 5
pseudoA = &pseudoA
# 5

# NEVER change DEPENDENCIES
RNA_edit_bin = /home/yeo-lab/software/RNA_editing
HashJoin = /home/yeo-lab/software/bin/hashjoin.pl
snpEFF = /home/yeo-lab/software/snpEff_2_0_5d/
SUFFIXES = sorted.bam sorted.bam.bai bcf var vcf eff5 eff5-10 eff10 noSNP conf conf$(MinConfidence).regions conf$(MinConfidence).no100 conf$(MinConfidence) conf$(MinConfidence).csv conf$(MinConfidence).bed conf$(MinConfidence).bb 

all_stages: stage1 stage2 stage3 
stage3: $(foreach SUFF, $(SUFFIXES), $(addsuffix .$(SUFF), $(SAMPLE)_stage3 )) # $(SAMPLE)_stage3.allCov.txt
stage2: $(foreach SUFF, $(SUFFIXES), $(addsuffix .$(SUFF), $(SAMPLE)_stage2 )) $(SAMPLE)_stage2.bam $(SAMPLE)_stage2.rmdup.bam 
stage1: $(foreach SUFF, $(SUFFIXES), $(addsuffix .$(SUFF), $(SAMPLE)_stage1 ))

.PHONY: stage1 stage2 stage3 all_stages -b

clean:
	rm -f *stage*

snpEff.config:
	ln -s $(snpEFF)/snpEff.config ./

%_stage3.sorted.bam: %_stage2.rmdup.bam $(RNA_edit_bin)/filterNonAG.pl
	echo "Filtering out reads with C or G mismatches" >> $(SAMPLE).make.out
	samtools view -F 256 -h $< | perl $(RNA_edit_bin)/filterNonAG.pl | samtools view -Sb - > $@
	samtools view $@ | wc
	echo >> $(SAMPLE).make.out

%_stage2.bam: %_stage1.sorted.bam -b %_stage1.conf$(MinConfidence).bed 
	echo "Selecting reads that overlap confident sites" >> $(SAMPLE).make.out
	bedtools intersect -$(S) -wa -abam $^ > $@
	samtools view $@ | wc
	echo >> $(SAMPLE).make.out

%_stage2.rmdup.bam: %_stage2.bam
	echo "Removing duplicates from $<" >> $(SAMPLE).make.out
	samtools rmdup $< $@
	samtools view $@ | wc
	echo >> $(SAMPLE).make.out

%_stage2.sorted.bam: %_stage2.rmdup.bam $(RNA_edit_bin)/filterNonAG.pl
	echo "Filtering out reads with C or G mismatches" >> $(SAMPLE).make.out
	samtools view -h $< | perl $(RNA_edit_bin)/filterNonAG.pl | samtools view -Sb - > $@
	samtools view $@ | wc
	echo >> $(SAMPLE).make.out

%_stage1.sorted.bam: %.bam
	echo "filter out unmapped reads from $<" >> $(SAMPLE).make.out
	samtools view -bF 4 $< > $@ 
#	rm $@
#	ln -s $^ $@
#	samtools sort -m 10000000000 $< > $@

%.sorted.bam.bai: %.sorted.bam
	echo "Indexing $<" >> $(SAMPLE).make.out
	samtools index $<

%.bcf: %.sorted.bam
	echo "Piling up reads on each editing site of $<" >> $(SAMPLE).make.out
	samtools mpileup -d 1000 -E -f $(FA) -D -g -I  $< > $@
	bcftools index $@
	echo >> $(SAMPLE).make.out

%.var: %.bcf $(RNA_edit_bin)/vcf2eff2KO.pl
	echo "De-compressing $< and selecting all variants" >> $(SAMPLE).make.out
	bcftools view $< | perl $(RNA_edit_bin)/vcf2eff2KO.pl - 1 > $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.vcf: %.bcf $(RNA_edit_bin)/vcf2eff.pl snpEff.config
	echo "De-compressing $< , selecting AtoG variants only and annotating with snpEff" >> $(SAMPLE).make.out
	bcftools view $< | perl $(RNA_edit_bin)/vcf2eff.pl - 1 | java -classpath $(snpEFF) -jar $(snpEFF)/snpEff.jar -o vcf -chr 'chr' $(snpEffDB) | perl $(RNA_edit_bin)/vcf2eff.pl - 1 > $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.eff10: %.vcf $(RNA_edit_bin)/vcf2eff.pl
	echo "Increasing coverage threshold to 10 and annotating with snpEff" >> $(SAMPLE).make.out
	perl $(RNA_edit_bin)/vcf2eff.pl $< 10 > $@ 
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.eff5: %.vcf $(RNA_edit_bin)/vcf2eff.pl
	echo "Increasing coverage threshold to 5 and annotating with snpEff" >> $(SAMPLE).make.out
	perl $(RNA_edit_bin)/vcf2eff.pl $< 5 > $@ 
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.eff5-10: %.eff5 %.eff10
	echo "Restricting coverage threshold between 5 and 10 reads" >> $(SAMPLE).make.out
	head -n 6 $< > $@
	sort -gk 1,2 $^ | uniq -u >> $@ 
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

#$(SAMPLE)_stage2.noSNP: $(SAMPLE)_stage2.eff5 $(SAMPLE)_stage2.noSNP
#	echo "Filtering out SNPs from and joining $^" >> $(SAMPLE).make.out
#	grep "^#CHROM" $< > $@
#	zcat $(SNP_DB) | perl -lane 'print "$$F[1]\t",$$F[2]-0' | $(HashJoin) -r -k 0,1 -v 0 -j 0,1 -o 0-9 - $< - | $(HashJoin) -k 0,1 -v 2-L1 -j 0,1 -o 0,1,v - $(SAMPLE)_stage2.noSNP - >> $@
#	wc $@ >> $(SAMPLE).make.out
#	echo >> $(SAMPLE).make.out

%.noSNP: %.eff5
	echo "Filtering out SNPs from $<" >> $(SAMPLE).make.out
#	grep "^#CHROM" $< > $@
	zcat $(SNP_DB) | perl -lane 'print "$$F[1]\t",$$F[2]-0' | $(HashJoin) -r -k 0,1 -v 0 -j 0,1 -o 0-9 - $< - >> $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.conf: %.noSNP $(RNA_edit_bin)/rankEdits.py
	echo "Calculating confidence for $<" >> $(SAMPLE).make.out
	python $(RNA_edit_bin)/rankEdits.py $< $(pseudoG) $(pseudoA) $(MinEditFrac) 0 > $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.conf$(MinConfidence): %.conf
	echo "Thresholding confidence > $(MinConfidence) for $<" >> $(SAMPLE).make.out
	cat $< | perl -lane 'print if $$F[5]>$(MinConfidence)' > $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.conf$(MinConfidence).no100: %.conf$(MinConfidence)
	echo "Filtering out SNPs from $<" >> $(SAMPLE).make.out
	perl -ane 'print if $$F[7] < 1.0' $< > $@ 
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.conf$(MinConfidence).bed: %.conf$(MinConfidence).no100
	echo '$(date +"%Y%m%d%H%M")  Converting $< to BED format' >> $(SAMPLE).make.out
	perl -le 'print "#CHROM\tPOS-1\tPOS\t%EDIT\tCOVER\tSTRAND" ' > $@
	perl -lane 'next if m/^\#/; $$strand = "." ; $$strand = "+" if $$F[3] eq "A" ; $$strand = "-" if $$F[3] eq "T" ; print join("\t",($$F[0],$$F[1]-1,$$F[1],int($$F[7]*100),int($$F[2]/10),$$strand))' $< >> $@
	wc $@ >> $(SAMPLE).make.out
	echo >> $(SAMPLE).make.out

%.allCov.txt: %_stage3.sorted.bam -b %.conf$(MinConfidence).bed 
	echo "Checking coverage by stage3 reads" >> $(SAMPLE).make.out
	bedtools coverage -abam $^ > $@
	wc -l $@
	echo >> $(SAMPLE).make.out

%.csv: %.no100
	echo "Converting to CSV: $<" >> $(SAMPLE).make.out
	perl -F"\t" -ane '$$F[4] =~ s/\,.//; print join(",",@F) if not m/\##/' $< > $@ 
	echo >> $(SAMPLE).make.out

%.regions: %.no100
	echo "Tallying confident sites in genic regions" >> $(SAMPLE).make.out
	cut -f 9 $< | perl -ane 's/\;/\n/g ; print' | sort | uniq -c > $@
	echo >> $(SAMPLE).make.out

%.bb: %.bed
	echo "Converting confident sites to bigBED format" >> $(SAMPLE).make.out
	bedToBigBed $< $(FA).fai $@
	echo >> $(SAMPLE).make.out
