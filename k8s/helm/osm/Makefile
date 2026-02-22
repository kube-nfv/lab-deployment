update:
	rm -rf charts
	helm pull oci://osm.etsi.org:5050/osm/devops/osm --untar --untardir charts
	helm dependency update charts/osm
