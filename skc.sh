#####################
# Help, basic setup #
#####################
if [ -n "$BASH_VERSION" ]; then
  SKC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "$ZSH_VERSION" ]; then
  SKC_DIR="$(cd "$(dirname "${(%):-%N}")" && pwd)"
else
  echo "Your shell is not supported. Please add script config path to the script!"
fi

function display_available_kubeconfigs {
	echo "Available kubeconfig files:"
	find $SKC_DIR/config -iname '*.yaml' -not -iname 'current*' -exec basename {} .yaml \; | xargs -I{} echo "  - {}"
}

function display_available_namespaces {
	echo "Available namespaces:"
	cat $SKC_DIR/config/namespaces | cut -d',' -f1 | xargs -I{} echo "  - {}"
}

function display_available_subcommands {
	echo "Available subcommands:"
	for subcommand_file in `find $SKC_DIR/subcommands -not -iname "*.example" -type f -executable`; do
		echo " - `basename $subcommand_file | cut -d'.' -f1`"
		$subcommand_file _usage_ | sed 's/^/      /'
		echo
	done
}

function clean_variables {
	unset SKC_DIR SKC_KUBECONFIG SKC_NAMESPACE SKC_SUFFIX SKC_SUBCOMMAND SKC_MODE
}

# Handle commands for displaying available resources
if [[ $1 == "kubeconfigs" ]]; then
	display_available_kubeconfigs
	clean_variables
	return
elif [[ $1 == "namespaces" ]]; then
	display_available_namespaces
	clean_variables
	return
elif [[ $1 == "subcommands" ]]; then
	display_available_subcommands
	clean_variables
	return
fi

# Display usage when arguments are missing
if [[ $1 == "" || $2 == "" ]]; then
	echo "Usage (switching context): skc KUBECONFIG NAMESPACE [SUBCOMMAND]"
	echo "Usage (just running subcommand): skc - [SUBCOMMAND]"
	echo "Use 'skc kubeconfigs' to list available kubeconfigs."
	echo "Use 'skc namespaces' to list available kubeconfigs."
	echo "Use 'skc subcommands' to list available kubeconfigs."
	echo
	[[ $1 == "" ]] && display_available_kubeconfigs
	display_available_namespaces
	unset SKC_DIR
	return
fi

# Set execution mode
if [[ $1 == "-" || $1 == "--" ]]; then
	SKC_MODE="subcommand-standalone"
else
	SKC_MODE="switch-context"
fi

#######################
# Argument validation #
#######################
function validate_and_set_kubeconfig {
	SKC_KUBECONFIG="$SKC_DIR/config/$1.yaml"
	if [[ ! -f $SKC_KUBECONFIG ]]; then
		echo "There is no kube config named $1"
		display_available_namespaces
		clean_variables
		return 1
	fi
	return 0
}

function validate_and_set_namespace {
	SKC_NAMESPACE=`cat $SKC_DIR/config/namespaces | grep -P "^$1," | cut -d',' -f2`
	if [[ $1 == "" || $SKC_NAMESPACE == "" ]]; then
		echo "There is no namespace named $1"
		display_available_namespaces
		clean_variables
		return 1
	fi
	return 0
}

function validate_and_set_subcommand {
	SKC_SUBCOMMAND=`find $SKC_DIR/subcommands -type f -executable -iname "$1.*" -not -iname "*.example"`
	if [[ $SKC_SUBCOMMAND == "" ]]; then
		echo "There is no subcommand named $1"
		display_available_subcommands
		clean_variables
		return 1
	elif [[ `echo $SKC_SUBCOMMAND | wc -l` != 1 ]]; then
		echo "There are multiple executable files for that subcommand"
		clean_variables
		return 1
	fi
	return 0
}

if [[ $SKC_MODE == "switch-context" ]]; then
	validate_and_set_kubeconfig $1 || return
	validate_and_set_namespace $2 || return
	if [[ $3 != "" ]]; then
		validate_and_set_subcommand $3 || return
	fi
elif [[ $SKC_MODE == "subcommand-standalone" ]]; then
	validate_and_set_subcommand $2 || return
else
	echo "Error! Please report it to skc owner!"
fi

#################################################################################
# Switching context (decryption, kubeconfig handling) and/or running subcommand #
#################################################################################
function remove_current_kubeconfig {
	# Check if KUBECONFIG variable is set by SKC
	if [[ $KUBECONFIG == *"$SKC_DIR/config"* ]]; then
		rm $KUBECONFIG
	fi
}

function decrypt_kubeconfig_and_set_random_suffix {
	SKC_SUFFIX=`cat /dev/urandom | tr -dc 'a-zA-Z0-0' | head -c 6`
	if ! gpg --output $SKC_DIR/config/current-$$-$SKC_SUFFIX.yaml -d --no-symkey-cache $SKC_KUBECONFIG; then
		echo "Could not decrypt kubeconfig. Exiting..."
		clean_variables
		return 1
	fi
	return 0
}

function export_kubeconfig_and_set_context_namespace {
	echo "export KUBECONFIG=$SKC_DIR/config/current-$$-$SKC_SUFFIX.yaml"
	export KUBECONFIG="$SKC_DIR/config/current-$$-$SKC_SUFFIX.yaml"
	echo "kubectl config set-context --current --namespace=$SKC_NAMESPACE"
	kubectl config set-context --current --namespace=$SKC_NAMESPACE
	export SKC_CURRENT_CTX="$SKC_KUBECONFIG $SKC_NAMESPACE"
}

function run_subcommand_if_set {
	if [[ $SKC_SUBCOMMAND != "" ]]; then
		$SKC_SUBCOMMAND $@
	fi
}

if [[ $SKC_MODE == "switch-context" ]]; then
	if [[ "$SKC_CURRENT_CTX" != "$SKC_KUBECONFIG $SKC_NAMESPACE" ]]; then
		# if the requested context is not equal to the current one, change it
		decrypt_kubeconfig_and_set_random_suffix || return
		remove_current_kubeconfig
		trap remove_current_kubeconfig EXIT
		export_kubeconfig_and_set_context_namespace
	fi
	run_subcommand_if_set ${@:4}
elif [[ $SKC_MODE == "subcommand-standalone" ]]; then
	run_subcommand_if_set ${@:3}
else
	echo "Error!"
fi

clean_variables