export const DirectoryPicker = {
    mounted() {
      this.handleDirectoryPicker();
    },
  
    handleDirectoryPicker() {
      // Create a hidden input element
      const input = document.createElement('input');
      input.type = 'file';
      input.webkitdirectory = true; // For Chrome/Safari
      input.directory = true; // For Firefox
      input.style.display = 'none';
  
      input.addEventListener('change', (e) => {
        if (e.target.files.length > 0) {
          // Get the selected directory path
          const path = e.target.files[0].path;
          const directory = path.substring(0, path.lastIndexOf('/'));
          
          // Push the event to the LiveView
          this.pushEvent("directory_selected", { directory });
        }
      });
  
      // Trigger the file picker
      input.click();
    }
  };