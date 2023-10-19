
######################################
# Set your desired file names
######################################
source_file="filelist.f"	# Name of your source file


######################################
# Simulation Option and Command
######################################


# =====================================
# ============== irun =================
# =====================================
IRUN_RTL_SIM =  irun -f ${source_file} \
	-libext .v \
	-loadpli1 debpli:novas_pli_boot \
	-debug \
	-notimingchecks \
	-define RTL
 
# =====================================	
# ============= clean =================
# =====================================
clean_irun = rm -rf *.fsdb *.sdf.X ./INCA_libs *.history *.log
# =====================================

run:
	${IRUN_RTL_SIM}

clean:
	${clean_irun}

