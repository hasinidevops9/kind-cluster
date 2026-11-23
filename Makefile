.PHONY: init apply destroy

# Optional gitignored terraform.tfvars. TF_VAR_ssh_password is read by Terraform itself.
TF_APPLY_ARGS = -auto-approve
ifneq ($(wildcard terraform.tfvars),)
TF_APPLY_ARGS += -var-file=terraform.tfvars
endif

init:
	terraform init

apply: init
	terraform apply $(TF_APPLY_ARGS)

destroy: init
	terraform destroy $(TF_APPLY_ARGS)
